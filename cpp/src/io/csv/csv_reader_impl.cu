/*
 * Copyright (c) 2018, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
	 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * @file csv-reader.cu  code to read csv data
 *
 * CSV Reader
 */

#include "csv_reader_impl.hpp"

#include <cuda_runtime.h>

#include <algorithm>
#include <iostream>
#include <numeric>
#include <string>
#include <vector>
#include <memory>
#include <unordered_map>
#include <cstring>

#include <stdio.h>
#include <stdlib.h>

#include <unistd.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/mman.h>

#include <thrust/scan.h>
#include <thrust/reduce.h>
#include <thrust/device_ptr.h>
#include <thrust/execution_policy.h>

#include <thrust/host_vector.h>

#include "type_conversion.cuh"
#include "datetime_parser.cuh"

#include <cudf/cudf.h>
#include <utilities/error_utils.hpp>
#include <utilities/trie.cuh>
#include <utilities/type_dispatcher.hpp>
#include <utilities/cudf_utils.h> 

#include <nvstrings/NVStrings.h>

#include <rmm/rmm.h>
#include <rmm/thrust_rmm_allocator.h>
#include <io/comp/io_uncomp.h>

#include <io/cuio_common.hpp>
#include <io/utilities/parsing_utils.cuh>

using std::vector;
using std::string;

namespace cudf {

using string_pair = std::pair<const char*,size_t>;


__global__ void convertCsvToGdf(char *csv, const ParseOptions opts,
                                gdf_size_type num_records, int num_columns,
                                bool *parseCol, uint64_t *recStart,
                                gdf_dtype *dtype, void **gdf_data,
                                gdf_valid_type **valid,
                                gdf_size_type *num_valid);
__global__ void dataTypeDetection(char *raw_csv, const ParseOptions opts,
                                  gdf_size_type num_records, int num_columns,
                                  bool *parseCol, uint64_t *recStart,
                                  column_data_t *d_columnData);

/**---------------------------------------------------------------------------*
 * @brief Estimates the maximum expected length or a row, based on the number 
 * of columns
 * 
 * If the number of columns is not available, it will return a value large 
 * enough for most use cases
 * 
 * @param[in] num_columns Number of columns in the CSV file (optional)
 * 
 * @return Estimated maximum size of a row, in bytes
 *---------------------------------------------------------------------------**/
 constexpr size_t calculateMaxRowSize(int num_columns=0) noexcept {
	constexpr size_t max_row_bytes = 16*1024; // 16KB
	constexpr size_t column_bytes = 64;
	constexpr size_t base_padding = 1024; // 1KB
	if (num_columns == 0){
		// Use flat size if the number of columns is not known
		return max_row_bytes;
	}
	else {
		// Expand the size based on the number of columns, if available
		return base_padding + num_columns * column_bytes; 
	}
}
/**
* @brief Removes the first and Last quote in the string
*/
string removeQuotes(string str, char quotechar) {
	// Exclude first and last quotation char
	const size_t first_quote = str.find(quotechar);
	if (first_quote != string::npos) {
		str.erase(first_quote, 1);
	}
	const size_t  last_quote = str.rfind(quotechar);
	if (last_quote != string::npos) {
		str.erase(last_quote, 1);
	}

	return str;
}

/**
 * @brief Parse the first row to set the column names in the raw_csv parameter 
 *
 * The first row can be either the header row, or the first data row
 *
 * @return void
*/
void CsvReader::Impl::setColumnNamesFromCsv() {
	vector<char> first_row = header;
	// No header, read the first data row
	if (first_row.empty()) {
		uint64_t first_row_len{};
		// If file only contains one row, recStart[1] is not valid
		if (num_records > 1) {
			CUDA_TRY(cudaMemcpy(&first_row_len, recStart.data() + 1, sizeof(uint64_t), cudaMemcpyDefault));
		}
		else {
			// File has one row - use the file size for the row size
			first_row_len = num_bytes / sizeof(char);
		}
		first_row.resize(first_row_len);
		CUDA_TRY(cudaMemcpy(first_row.data(), data.data(), first_row_len * sizeof(char), cudaMemcpyDefault));
	}

	int num_cols = 0;

	bool quotation	= false;
	for (size_t pos = 0, prev = 0; pos < first_row.size(); ++pos) {
		// Flip the quotation flag if current character is a quotechar
		if(first_row[pos] == opts.quotechar) {
			quotation = !quotation;
		}
		// Check if end of a column/row
		else if (pos == first_row.size() - 1 ||
				 (!quotation && first_row[pos] == opts.terminator) ||
				 (!quotation && first_row[pos] == opts.delimiter)) {
			// This is the header, add the column name
			if (args_.header >= 0) {
				// Include the current character, in case the line is not terminated
				int col_name_len = pos - prev + 1;
				// Exclude the delimiter/terminator is present
				if (first_row[pos] == opts.delimiter || first_row[pos] == opts.terminator) {
					--col_name_len;
				}
				// Also exclude '\r' character at the end of the column name if it's part of the terminator
				if (col_name_len > 0 &&
					opts.terminator == '\n' &&
					first_row[pos] == '\n' &&
					first_row[pos - 1] == '\r') {
					--col_name_len;
				}

				const string new_col_name(first_row.data() + prev, col_name_len);
				col_names.push_back(removeQuotes(new_col_name, opts.quotechar));

				// Stop parsing when we hit the line terminator; relevant when there is a blank line following the header.
				// In this case, first_row includes multiple line terminators at the end, as the new recStart belongs
				// to a line that comes after the blank line(s)
				if (!quotation && first_row[pos] == opts.terminator){
					break;
				}
			}
			else {
				// This is the first data row, add the automatically generated name
				col_names.push_back(args_.prefix + std::to_string(num_cols));
			}
			num_cols++;

			// Skip adjacent delimiters if delim_whitespace is set
			while (opts.multi_delimiter &&
				   pos < first_row.size() &&
				   first_row[pos] == opts.delimiter && 
				   first_row[pos + 1] == opts.delimiter) {
				++pos;
			}
			prev = pos + 1;
		}
	}
}

/**---------------------------------------------------------------------------*
 * @brief Updates the object with the total number of rows and
 * quotation characters in the file
 *
 * Does not count the quotations if quotechar is set to '/0'.
 *
 * @param[in] h_data Pointer to the csv data in host memory
 * @param[in] h_size Size of the input data, in bytes
 *
 * @return void
 *---------------------------------------------------------------------------**/
void CsvReader::Impl::countRecordsAndQuotes(const char *h_data, size_t h_size) {
	vector<char> chars_to_count{opts.terminator};
	if (opts.quotechar != '\0') {
		chars_to_count.push_back(opts.quotechar);
	}

	num_records = countAllFromSet(h_data, h_size, chars_to_count);

	// If not starting at an offset, add an extra row to account for the first row in the file
	if (byte_range_offset == 0) {
		++num_records;
	}
}

/**---------------------------------------------------------------------------*
 * @brief Updates the object with the offset of each row in the file
 * Also add positions of each quotation character in the file.
 *
 * Does not process the quotations if quotechar is set to '/0'.
 *
 * @param[in] h_data Pointer to the csv data in host memory
 * @param[in] h_size Size of the input data, in bytes
 *
 * @return void
 *---------------------------------------------------------------------------**/
void CsvReader::Impl::setRecordStarts(const char *h_data, size_t h_size) {
	// Allocate space to hold the record starting points
	const bool last_line_terminated = (h_data[h_size - 1] == opts.terminator);
	// If the last line is not terminated, allocate space for the EOF entry (added later)
	const gdf_size_type record_start_count = num_records + (last_line_terminated ? 0 : 1);
	recStart = device_buffer<uint64_t>(record_start_count); 

	auto* find_result_ptr = recStart.data();
	if (byte_range_offset == 0) {
		find_result_ptr++;
		CUDA_TRY(cudaMemsetAsync(recStart.data(), 0ull, sizeof(uint64_t)));
	}
	vector<char> chars_to_find{opts.terminator};
	if (opts.quotechar != '\0') {
		chars_to_find.push_back(opts.quotechar);
	}
	// Passing offset = 1 to return positions AFTER the found character
	findAllFromSet(h_data, h_size, chars_to_find, 1, find_result_ptr);

	// Previous call stores the record pinput_file.typeositions as encountered by all threads
	// Sort the record positions as subsequent processing may require filtering
	// certain rows or other processing on specific records
	thrust::sort(rmm::exec_policy()->on(0), recStart.data(), recStart.data() + num_records);

	// Currently, ignoring lineterminations within quotes is handled by recording
	// the records of both, and then filtering out the records that is a quotechar
	// or a linetermination within a quotechar pair. The future major refactoring
	// of csv_reader and its kernels will probably use a different tactic.
	if (opts.quotechar != '\0') {
		vector<uint64_t> h_rec_starts(num_records);
		const size_t rec_start_size = sizeof(uint64_t) * (h_rec_starts.size());
		CUDA_TRY( cudaMemcpy(h_rec_starts.data(), recStart.data(), rec_start_size, cudaMemcpyDeviceToHost) );

		auto recCount = num_records;

		bool quotation = false;
		for (gdf_size_type i = 1; i < num_records; ++i) {
			if (h_data[h_rec_starts[i] - 1] == opts.quotechar) {
				quotation = !quotation;
				h_rec_starts[i] = num_bytes;
				recCount--;
			}
			else if (quotation) {
				h_rec_starts[i] = num_bytes;
				recCount--;
			}
		}

		CUDA_TRY( cudaMemcpy(recStart.data(), h_rec_starts.data(), rec_start_size, cudaMemcpyHostToDevice) );
		thrust::sort(rmm::exec_policy()->on(0), recStart.data(), recStart.data() + num_records);
		num_records = recCount;
	}

	if (!last_line_terminated){
		// Add the EOF as the last record when the terminator is missing in the last line
		const uint64_t eof_offset = h_size;
		CUDA_TRY(cudaMemcpy(recStart.data() + num_records, &eof_offset, sizeof(uint64_t), cudaMemcpyDefault));
		// Update the record count
		++num_records;
	}
}

/**---------------------------------------------------------------------------*
 * @brief Reads CSV-structured data and returns an array of gdf_columns.
 *
 * @return void
 *---------------------------------------------------------------------------**/
table CsvReader::Impl::read()
{
	// TODO move initialization to constructor
	num_actual_cols = args_.names.size();
	num_active_cols = args_.names.size();

	if (args_.delim_whitespace) {
		opts.delimiter = ' ';
		opts.multi_delimiter = true;
	} else {
		opts.delimiter = args_.delimiter;
		opts.multi_delimiter = false;
	}
	opts.terminator = args_.lineterminator;
	if (args_.quotechar != '\0' && args_.quoting != QUOTE_NONE) {
		opts.quotechar = args_.quotechar;
		opts.keepquotes = false;
		opts.doublequote = args_.doublequote;
	} else {
		opts.quotechar = '\0';
		opts.keepquotes = true;
		opts.doublequote = false;
	}
	opts.skipblanklines = args_.skip_blank_lines;
	opts.comment = args_.comment;
	opts.dayfirst = args_.dayfirst;
	opts.decimal = args_.decimal;
	opts.thousands = args_.thousands;
	CUDF_EXPECTS(opts.decimal != opts.delimiter, "Decimal point cannot be the same as the delimiter");
	CUDF_EXPECTS(opts.thousands != opts.delimiter, "Thousands separator cannot be the same as the delimiter");

  const string compression_type =
      inferCompressionType(args_.compression, args_.input_data_form, args_.filepath_or_buffer,
                           {{"csv", "none"}, {"gz", "gzip"}, {"zip", "zip"}, {"bz2", "bz2"}, {"xz", "xz"}});

	if (byte_range_offset > 0 || byte_range_size > 0) {
		CUDF_EXPECTS(compression_type == "none", 
			"Cannot read compressed input when using the byte range parameter");
	}

	// Handle user-defined booleans values, whereby field data is substituted
	// with true/false values; CUDF booleans are int types of 0 or 1
	vector<string> true_values{"True", "TRUE", "true"};
	true_values.insert(true_values.end(), args_.true_values.begin(), args_.true_values.end());

	d_trueTrie = createSerializedTrie(true_values);
	opts.trueValuesTrie = d_trueTrie.data().get();

	vector<string> false_values{"False", "FALSE", "false"};
	false_values.insert(false_values.end(), args_.false_values.begin(), args_.false_values.end());
	d_falseTrie = createSerializedTrie(false_values);
	opts.falseValuesTrie = d_falseTrie.data().get();

	if (args_.na_filter && (args_.keep_default_na || !args_.na_values.empty())) {
		vector<string> na_values{
			"#N/A", "#N/A N/A", "#NA", "-1.#IND", 
			"-1.#QNAN", "-NaN", "-nan", "1.#IND", 
			"1.#QNAN", "N/A", "NA", "NULL", 
			"NaN", "n/a", "nan", "null"};
		if(!args_.keep_default_na){
			na_values.clear();
		}
		na_values.insert(na_values.end(), args_.na_values.begin(), args_.na_values.end());

		d_naTrie = createSerializedTrie(na_values);
		opts.naValuesTrie = d_naTrie.data().get();
	}

	//-----------------------------------------------------------------------------
	// memory map in the data
	const void * map_data = nullptr;
	size_t	map_size = 0;
	size_t	map_offset = 0;
	int fd = 0;
	if (args_.input_data_form == gdf_input_type::FILE_PATH)
	{
		fd = open(args_.filepath_or_buffer.c_str(), O_RDONLY );
		if (fd < 0) { close(fd); CUDF_FAIL("Error opening file"); }

		struct stat st{};
		if (fstat(fd, &st)) { close(fd); CUDF_FAIL("cannot stat file"); }
	
		const auto file_size = st.st_size;
		if (byte_range_offset > (size_t)file_size) {
			close(fd);
			CUDF_FAIL("The byte_range offset is larger than the file size");
		}

		// Can't map an empty file, will return an empty dataframe further down
		if (file_size != 0) {
			// Have to align map offset to page size
			const auto page_size = sysconf(_SC_PAGESIZE);
			map_offset = (byte_range_offset/page_size)*page_size;

			// Set to rest-of-the-file size, will reduce based on the byte range size
			num_bytes = map_size = file_size - map_offset;

			// Include the page padding in the mapped size
			const size_t page_padding = byte_range_offset - map_offset;
			const size_t padded_byte_range_size = byte_range_size + page_padding;

			if (byte_range_size != 0 && padded_byte_range_size < map_size) {
				// Need to make sure that w/ padding we don't overshoot the end of file
				map_size = min(padded_byte_range_size + calculateMaxRowSize(std::max(args_.names.size(), args_.dtype.size())), map_size);
			}

			// Ignore page padding for parsing purposes
			num_bytes = map_size - page_padding;

			map_data = mmap(0, map_size, PROT_READ, MAP_PRIVATE, fd, map_offset);
			if (map_data == MAP_FAILED || map_size==0) { close(fd); CUDF_FAIL("Error mapping file"); }
		}
	}
	else if (args_.input_data_form == gdf_input_type::HOST_BUFFER)
	{
		map_data = args_.filepath_or_buffer.c_str();
		num_bytes = map_size = args_.filepath_or_buffer.size();
	}
	else { CUDF_FAIL("invalid input type"); }

	// Return an empty dataframe if the input is empty and user did not specify the column names and types
	if (num_bytes == 0 && (args_.names.empty() || args_.dtype.empty())){
		return table();
	}

	const char* h_uncomp_data = nullptr;
	size_t h_uncomp_size = 0;
	// Used when the input data is compressed, to ensure the allocated uncompressed data is freed
	vector<char> h_uncomp_data_owner;
	// Skip if the input is empty and proceed to set the column names and types based on user's input
	if(num_bytes != 0) {
		if (compression_type == "none") {
			// Do not use the owner vector here to avoid copying the whole file to the heap
			h_uncomp_data = (const char*)map_data + (byte_range_offset - map_offset);
			h_uncomp_size = num_bytes;
		}
		else {
			CUDF_EXPECTS(getUncompressedHostData((const char *)map_data, map_size, compression_type,
																					 h_uncomp_data_owner) == GDF_SUCCESS,
									 "Input data decompression failed.\n");
			h_uncomp_data = h_uncomp_data_owner.data();
			h_uncomp_size = h_uncomp_data_owner.size();
		}
	
		countRecordsAndQuotes(h_uncomp_data, h_uncomp_size);

		setRecordStarts(h_uncomp_data, h_uncomp_size);

		uploadDataToDevice(h_uncomp_data, h_uncomp_size);
	}

	//-----------------------------------------------------------------------------
	//---  done with host data
	if (args_.input_data_form == gdf_input_type::FILE_PATH)
	{
		close(fd);
		if (map_data != nullptr) {
			munmap((void*)map_data, map_size);
		}
	}

	//-----------------------------------------------------------------------------
	//-- Populate the header

	// Check if the user gave us a list of column names
	if(args_.names.empty()) {
		setColumnNamesFromCsv();

		num_actual_cols = num_active_cols = col_names.size();

		// Initialize a boolean array that states if a column needs to read or filtered.
		h_parseCol = thrust::host_vector<bool>(num_actual_cols, true);

		// Rename empty column names to "Unnamed: col_index"
		for (size_t col_idx = 0; col_idx < col_names.size(); ++col_idx) {
			if (col_names[col_idx].empty()) {
				col_names[col_idx] = string("Unnamed: ") + std::to_string(col_idx);
			}
		}

		// Looking for duplicates
		std::unordered_map<string, int> col_names_histogram;
		for (auto& col_name: col_names){
			// Operator [] inserts a default-initialized value if the given key is not present
			if (++col_names_histogram[col_name] > 1){
				if (args_.mangle_dupe_cols) {
					// Rename duplicates of column X as X.1, X.2, ...; First appearance stays as X
					col_name += "." + std::to_string(col_names_histogram[col_name] - 1);
				}
				else {
					// All duplicate columns will be ignored; First appearance is parsed
					const auto idx = &col_name - col_names.data();
					h_parseCol[idx] = false;
				}
			}
		}

		// Update the number of columns to be processed, if some might have been removed
		if (!args_.mangle_dupe_cols) {
			num_active_cols = col_names_histogram.size();
		}
	}
	else {
		h_parseCol = thrust::host_vector<bool>(args_.names.size(), true);
		col_names = args_.names;
	}

	// User can specify which columns should be parsed
	if (!args_.use_cols_indexes.empty() || !args_.use_cols_names.empty()){
		thrust::fill(h_parseCol.begin(), h_parseCol.end(), false);
		for(int col: args_.use_cols_indexes){
			h_parseCol[col]=true;
		}
		num_active_cols = args_.use_cols_indexes.size();

		std::set<string> use_cols_set(args_.use_cols_names.begin(), args_.use_cols_names.end());
		for(const std::string &col: col_names) {
			if(use_cols_set.find(col) != use_cols_set.end()){
				const auto pos = &col - col_names.data();
				h_parseCol[pos] = true;
				num_active_cols++;
			}
		}
	}

	d_parseCol = h_parseCol;

	//-----------------------------------------------------------------------------
	//--- Auto detect types of the vectors

  if(args_.dtype.empty()){
    if (num_records == 0) {
      dtypes = vector<gdf_dtype>(num_active_cols, GDF_STRING);
    } else {
      vector<column_data_t> h_ColumnData(num_active_cols);
      device_buffer<column_data_t> d_ColumnData(num_active_cols);
      CUDA_TRY(cudaMemset(d_ColumnData.data(), 0, sizeof(column_data_t) * num_active_cols));

      launch_dataTypeDetection(d_ColumnData.data());
      CUDA_TRY(cudaMemcpy(h_ColumnData.data(), d_ColumnData.data(), sizeof(column_data_t) * num_active_cols, cudaMemcpyDeviceToHost));

      // host: array of dtypes (since gdf_columns are not created until end)
      vector<gdf_dtype> d_detectedTypes;

      for(int col = 0; col < num_active_cols; col++){
        unsigned long long countInt = h_ColumnData[col].countInt8 + h_ColumnData[col].countInt16 +
                                      h_ColumnData[col].countInt32 + h_ColumnData[col].countInt64;

        if (h_ColumnData[col].countNULL == num_records){
          // Entire column is NULL; allocate the smallest amount of memory
          d_detectedTypes.push_back(GDF_INT8);
        } else if(h_ColumnData[col].countString > 0L){
          d_detectedTypes.push_back(GDF_STRING);
        } else if(h_ColumnData[col].countDateAndTime > 0L){
          d_detectedTypes.push_back(GDF_DATE64);
        } else if(h_ColumnData[col].countBool > 0L) {
          d_detectedTypes.push_back(GDF_BOOL8);
        } else if(h_ColumnData[col].countFloat > 0L ||
          (h_ColumnData[col].countFloat == 0L &&
           countInt > 0L && h_ColumnData[col].countNULL > 0L)) {
          // The second condition has been added to conform to
          // PANDAS which states that a column of integers with
          // a single NULL record need to be treated as floats.
          d_detectedTypes.push_back(GDF_FLOAT64);
        } else {
          // All other integers are stored as 64-bit to conform to PANDAS
          d_detectedTypes.push_back(GDF_INT64);
        }
      }
      dtypes = d_detectedTypes;
    }
  }
  else {
    const bool is_dict = std::all_of(args_.dtype.begin(), args_.dtype.end(),
                                     [](const auto& s) { return s.find(':') != std::string::npos; });
    if (!is_dict) {
      CUDF_EXPECTS(static_cast<int>(args_.dtype.size()) >= num_actual_cols,
                   "Must specify data types for all columns");
      for (int col = 0; col < num_actual_cols; col++) {
        if (h_parseCol[col]) {
          // dtype is an array of types, assign types to active columns in the given order
          dtypes.push_back(convertStringToDtype(args_.dtype[col]));
          CUDF_EXPECTS(dtypes.back() != GDF_invalid, "Unsupported data type");
        }
      }
    } else {
      // dtype is a column name->type dictionary, create a map from the dtype array to speed up processing
      std::unordered_map<std::string, gdf_dtype> col_type_map;
      for (const std::string & dtype: args_.dtype) {
        // Split the dtype elements around the last ':' character
        const size_t colon_idx = dtype.find_last_of(':');
        const std::string col(dtype, 0, colon_idx);
        const std::string type(dtype, colon_idx + 1);

        col_type_map[col] = convertStringToDtype(type);
        CUDF_EXPECTS(col_type_map[col] != GDF_invalid, "Unsupported data type");
      }

      for (int col = 0; col < num_actual_cols; col++) {
        if (h_parseCol[col]) {
          CUDF_EXPECTS(col_type_map.find(col_names[col]) != col_type_map.end(),
            "Must specify data types for all active columns");
          dtypes.push_back(col_type_map[col_names[col]]);
        }
      }
    }
  }
  // Alloc output; columns' data memory is still expected for empty dataframe
  std::vector<gdf_column_wrapper> columns;
  for (int col = 0, active_col = 0; col < num_actual_cols; ++col) {
    if (h_parseCol[col]) {
      columns.emplace_back(num_records, dtypes[active_col],
                           gdf_dtype_extra_info{TIME_UNIT_NONE},
                           col_names[col]);
      CUDF_EXPECTS(columns.back().allocate() == GDF_SUCCESS, "Cannot allocate columns");
      active_col++;
    }
  }

  // Convert CSV input to cuDF output
  if (num_records != 0) {
    thrust::host_vector<gdf_dtype> h_dtypes(num_active_cols);
    thrust::host_vector<void*> h_data(num_active_cols);
    thrust::host_vector<gdf_valid_type*> h_valid(num_active_cols);

    for (int i = 0; i < num_active_cols; ++i) {
      h_dtypes[i] = columns[i]->dtype;
      h_data[i] = columns[i]->data;
      h_valid[i] = columns[i]->valid;
    }

    rmm::device_vector<gdf_dtype> d_dtypes = h_dtypes;
    rmm::device_vector<void*> d_data = h_data;
    rmm::device_vector<gdf_valid_type*> d_valid = h_valid;
    rmm::device_vector<gdf_size_type> d_valid_counts(num_active_cols, 0);

    launch_dataConvertColumns(d_data.data().get(), d_valid.data().get(), d_dtypes.data().get(),
                              d_valid_counts.data().get());
    CUDA_TRY(cudaStreamSynchronize(0));

    thrust::host_vector<gdf_size_type> h_valid_counts = d_valid_counts;
    for (int i = 0; i < num_active_cols; ++i) {
      columns[i]->null_count = columns[i]->size - h_valid_counts[i];
    }
  }

  for (int i = 0; i < num_active_cols; ++i) {
    if (columns[i]->dtype == GDF_STRING) {
      std::unique_ptr<NVStrings, decltype(&NVStrings::destroy)> str_data(
        NVStrings::create_from_index(static_cast<string_pair *>(columns[i]->data), columns[i]->size), 
        &NVStrings::destroy);
      RMM_TRY(RMM_FREE(columns[i]->data, 0));

      // PANDAS' default behavior of enabling doublequote for two consecutive
      // quotechars in quoted fields results in reduction to a single quotechar
      if ((opts.quotechar != '\0') &&
          (opts.doublequote == true)) {
        const std::string quotechar(1, opts.quotechar);
        const std::string doublequotechar(2, opts.quotechar);
        columns[i]->data = str_data->replace(doublequotechar.c_str(), quotechar.c_str());
      }
      else {
        columns[i]->data = str_data.release();
      }
    }
  }

  // Transfer ownership to raw pointer output arguments
  std::vector<gdf_column *> out_cols(num_active_cols);
  for (size_t i = 0; i < out_cols.size(); ++i) {
    out_cols[i] = columns[i].release();
  }

  return table(out_cols.data(), out_cols.size());
}


/**---------------------------------------------------------------------------*
 * @brief Uploads the relevant segment of the input csv data onto the GPU.
 * 
 * Only rows that need to be read are copied to the GPU, based on parameters
 * like nrows, skipheader, skipfooter.
 * Also updates the array of record starts to match the device data offset.
 * 
 * @param[in] h_uncomp_data Pointer to the uncompressed csv data in host memory
 * @param[in] h_uncomp_size Size of the input data, in bytes
 * 
 * @return void
 *---------------------------------------------------------------------------**/
void CsvReader::Impl::uploadDataToDevice(const char *h_uncomp_data, size_t h_uncomp_size) {

  // Exclude the rows that are to be skipped from the start
  CUDF_EXPECTS(num_records > skiprows, "Skipping too many rows");
  const auto first_row = skiprows;
  num_records = num_records - first_row;

  std::vector<uint64_t> h_rec_starts(num_records);
  CUDA_TRY(cudaMemcpy(h_rec_starts.data(), recStart.data() + first_row,
                      sizeof(uint64_t) * h_rec_starts.size(),
                      cudaMemcpyDefault));

  // Trim lines that are outside range, but keep one greater for the end offset
  if (byte_range_size != 0) {
    auto it = h_rec_starts.end() - 1;
    while (it >= h_rec_starts.begin() &&
           *it > uint64_t(byte_range_size)) {
      --it;
    }
    if ((it + 2) < h_rec_starts.end()) {
      h_rec_starts.erase(it + 2, h_rec_starts.end());
    }
  }

  // Discard only blank lines, only fully comment lines, or both.
  // If only handling one of them, ensure it doesn't match against \0 as we do
  // not want certain scenarios to be filtered out (end-of-file)
  if (opts.skipblanklines || opts.comment != '\0') {
    const auto match_newline = opts.skipblanklines ? opts.terminator
                                                            : opts.comment;
    const auto match_comment = opts.comment != '\0' ? opts.comment
                                                             : match_newline;
    const auto match_return = (opts.skipblanklines &&
                              opts.terminator == '\n') ? '\r'
                                                                : match_comment;
    h_rec_starts.erase(
        std::remove_if(h_rec_starts.begin(), h_rec_starts.end(),
                       [&](uint64_t i) {
                         return (h_uncomp_data[i] == match_newline ||
                                 h_uncomp_data[i] == match_return ||
                                 h_uncomp_data[i] == match_comment);
                       }),
        h_rec_starts.end());
  }

  num_records = h_rec_starts.size();

  // Exclude the rows before the header row (inclusive)
  // But copy the header data for parsing the column names later (if necessary)
  if (args_.header >= 0) {
    header.assign(
        h_uncomp_data + h_rec_starts[args_.header],
        h_uncomp_data + h_rec_starts[args_.header + 1]);
    h_rec_starts.erase(h_rec_starts.begin(),
                       h_rec_starts.begin() + args_.header + 1);
    num_records = h_rec_starts.size();
  }

  // Exclude the rows that exceed past the requested number
  if (nrows >= 0 && nrows < num_records) {
    h_rec_starts.resize(nrows + 1);    // include end offset
    num_records = h_rec_starts.size();
  }

  // Exclude the rows that are to be skipped from the end
  if (skipfooter > 0) {
    h_rec_starts.resize(h_rec_starts.size() - skipfooter);
    num_records = h_rec_starts.size();
  }

  CUDF_EXPECTS(num_records > 0, "No data available for parsing");

  const auto start_offset = h_rec_starts.front();
  const auto end_offset = h_rec_starts.back();
  num_bytes = end_offset - start_offset;
  assert(num_bytes <= h_uncomp_size);
  num_bits = (num_bytes + 63) / 64;

  // Resize and upload the rows of interest
  recStart.resize(num_records);
  CUDA_TRY(cudaMemcpy(recStart.data(), h_rec_starts.data(),
                      sizeof(uint64_t) * num_records,
                      cudaMemcpyDefault));

  // Upload the raw data that is within the rows of interest
  data = device_buffer<char>(num_bytes);
  CUDA_TRY(cudaMemcpy(data.data(), h_uncomp_data + start_offset,
                      num_bytes, cudaMemcpyHostToDevice));

  // Adjust row start positions to account for the data subcopy
  thrust::transform(rmm::exec_policy()->on(0), recStart.data(),
                    recStart.data() + num_records,
                    thrust::make_constant_iterator(start_offset),
                    recStart.data(), thrust::minus<uint64_t>());

  // The array of row offsets includes EOF
  // reduce the number of records by one to exclude it from the row count
  num_records--;
}

/**---------------------------------------------------------------------------*
 * @brief Helper function to setup and launch CSV parsing CUDA kernel.
 * 
 * @param[out] gdf The output column data
 * @param[out] valid The bitmaps indicating whether column fields are valid
 * @param[out] str_cols The start/end offsets for string data types
 * @param[out] num_valid The numbers of valid fields in columns
 *
 * @return void
 *---------------------------------------------------------------------------**/
 void CsvReader::Impl::launch_dataConvertColumns(void **gdf,
                                    gdf_valid_type **valid, gdf_dtype *d_dtypes,
                                    gdf_size_type *num_valid) {
  int blockSize;    // suggested thread count to use
  int minGridSize;  // minimum block count required
  CUDA_TRY(cudaOccupancyMaxPotentialBlockSize(&minGridSize, &blockSize,
                                              convertCsvToGdf));

  // Calculate actual block count to use based on records count
  int gridSize = (num_records + blockSize - 1) / blockSize;

  convertCsvToGdf <<< gridSize, blockSize >>> (
      data.data(), opts, num_records,
      num_actual_cols, d_parseCol.data().get(), recStart.data(),
      d_dtypes, gdf, valid, num_valid);

  CUDA_TRY(cudaGetLastError());
}

/**---------------------------------------------------------------------------*
 * @brief Functor for converting CSV data to cuDF data type value.
 *---------------------------------------------------------------------------**/
struct ConvertFunctor {
  /**---------------------------------------------------------------------------*
   * @brief Template specialization for operator() for types whose values can be
   * convertible to a 0 or 1 to represent false/true. The converting is done by
   * checking against the default and user-specified true/false values list.
   *
   * It is handled here rather than within convertStrToValue() as that function
   * is used by other types (ex. timestamp) that aren't 'booleable'.
   *---------------------------------------------------------------------------**/
  template <typename T,
            typename std::enable_if_t<std::is_integral<T>::value> * = nullptr>
  __host__ __device__ __forceinline__ void operator()(
      const char *csvData, void *gdfColumnData, long rowIndex, long start,
      long end, const ParseOptions &opts) {
    T &value{static_cast<T *>(gdfColumnData)[rowIndex]};

    // Check for user-specified true/false values first, where the output is
    // replaced with 1/0 respectively
    const size_t field_len = end - start + 1;
    if (serializedTrieContains(opts.trueValuesTrie, csvData + start, field_len)) {
      value = 1;
    } else if (serializedTrieContains(opts.falseValuesTrie, csvData + start, field_len)) {
      value = 0;
    } else {
      value = convertStrToValue<T>(csvData, start, end, opts);
    }
  }

  /**---------------------------------------------------------------------------*
   * @brief Default template operator() dispatch specialization all data types
   * (including wrapper types) that is not covered by above.
   *---------------------------------------------------------------------------**/
  template <typename T,
            typename std::enable_if_t<!std::is_integral<T>::value> * = nullptr>
  __host__ __device__ __forceinline__ void operator()(
      const char *csvData, void *gdfColumnData, long rowIndex, long start,
      long end, const ParseOptions &opts) {
    T &value{static_cast<T *>(gdfColumnData)[rowIndex]};
    value = convertStrToValue<T>(csvData, start, end, opts);
  }
};

/**---------------------------------------------------------------------------*
 * @brief CUDA kernel that parses and converts CSV data into cuDF column data.
 * 
 * Data is processed one record at a time
 *
 * @param[in] raw_csv The entire CSV data to read
 * @param[in] opts A set of parsing options
 * @param[in] num_records The number of lines/rows of CSV data
 * @param[in] num_columns The number of columns of CSV data
 * @param[in] parseCol Whether to parse or skip a column
 * @param[in] recStart The start the CSV data of interest
 * @param[in] dtype The data type of the column
 * @param[out] gdf_data The output column data
 * @param[out] valid The bitmaps indicating whether column fields are valid
 * @param[out] num_valid The numbers of valid fields in columns
 *
 * @return void
 *---------------------------------------------------------------------------**/
__global__ void convertCsvToGdf(char *raw_csv, const ParseOptions opts,
                                gdf_size_type num_records, int num_columns,
                                bool *parseCol, uint64_t *recStart,
                                gdf_dtype *dtype, void **gdf_data,
                                gdf_valid_type **valid,
                                gdf_size_type *num_valid)
{
	// thread IDs range per block, so also need the block id
	long	rec_id  = threadIdx.x + (blockDim.x * blockIdx.x);		// this is entry into the field array - tid is an elements within the num_entries array

	// we can have more threads than data, make sure we are not past the end of the data
	if ( rec_id >= num_records)
		return;

	long start 		= recStart[rec_id];
	long stop 		= recStart[rec_id + 1];

	long pos 		= start;
	int  col 		= 0;
	int  actual_col = 0;

	while(col<num_columns){

		if(start>stop)
			break;

		pos = seekFieldEnd(raw_csv, opts, pos, stop);

		if(parseCol[col]==true){

			// check if the entire field is a NaN string - consistent with pandas
			const bool is_na = serializedTrieContains(opts.naValuesTrie, raw_csv + start, pos - start);

			// Modify start & end to ignore whitespace and quotechars
			long tempPos=pos-1;
			if(!is_na && dtype[actual_col] != gdf_dtype::GDF_CATEGORY && dtype[actual_col] != gdf_dtype::GDF_STRING){
				adjustForWhitespaceAndQuotes(raw_csv, &start, &tempPos, opts.quotechar);
			}

			if(!is_na && start<=(tempPos)) { // Empty fields are not legal values

				// Type dispatcher does not handle GDF_STRINGS
				if (dtype[actual_col] == gdf_dtype::GDF_STRING) {
					long end = pos;
					if(opts.keepquotes==false){
						if((raw_csv[start] == opts.quotechar) && (raw_csv[end-1] == opts.quotechar)){
							start++;
							end--;
						}
					}
					auto str_list = static_cast<string_pair*>(gdf_data[actual_col]);
					str_list[rec_id].first = raw_csv + start;
					str_list[rec_id].second = end - start;
				} else {
					cudf::type_dispatcher(
						dtype[actual_col], ConvertFunctor{}, raw_csv,
						gdf_data[actual_col], rec_id, start, tempPos, opts);
				}

				// set the valid bitmap - all bits were set to 0 to start
				setBitmapBit(valid[actual_col], rec_id);
				atomicAdd(&num_valid[actual_col], 1);
			}
			else if(dtype[actual_col]==gdf_dtype::GDF_STRING){
				auto str_list = static_cast<string_pair*>(gdf_data[actual_col]);
				str_list[rec_id].first = nullptr;
				str_list[rec_id].second = 0;
			}
			actual_col++;
		}
		pos++;
		start=pos;
		col++;

	}
}

/**---------------------------------------------------------------------------*
 * @brief Helper function to setup and launch CSV data type detect CUDA kernel.
 * 
 * @param[in] raw_csv The metadata for the CSV data
 * @param[out] d_columnData The count for each column data type
 *
 * @return void
 *---------------------------------------------------------------------------**/
 void CsvReader::Impl::launch_dataTypeDetection(column_data_t *d_columnData) {
  int blockSize;    // suggested thread count to use
  int minGridSize;  // minimum block count required
  CUDA_TRY(cudaOccupancyMaxPotentialBlockSize(&minGridSize, &blockSize,
                                              dataTypeDetection));

  // Calculate actual block count to use based on records count
  int gridSize = (num_records + blockSize - 1) / blockSize;

  dataTypeDetection <<< gridSize, blockSize >>> (
      data.data(), opts, num_records,
      num_actual_cols, d_parseCol.data().get(), recStart.data(),
      d_columnData);

  CUDA_TRY(cudaGetLastError());
}

/**---------------------------------------------------------------------------*
 * @brief CUDA kernel that parses and converts CSV data into cuDF column data.
 *
 * Data is processed in one row/record at a time, so the number of total
 * threads (tid) is equal to the number of rows.
 *
 * @param[in] raw_csv The entire CSV data to read
 * @param[in] opts A set of parsing options
 * @param[in] num_records The number of lines/rows of CSV data
 * @param[in] num_columns The number of columns of CSV data
 * @param[in] parseCol Whether to parse or skip a column
 * @param[in] recStart The start the CSV data of interest
 * @param[out] d_columnData The count for each column data type
 *
 * @returns GDF_SUCCESS upon successful computation
 *---------------------------------------------------------------------------**/
__global__
void dataTypeDetection(char *raw_csv,
                       const ParseOptions opts,
                       gdf_size_type num_records,
                       int num_columns,
                       bool *parseCol,
                       uint64_t *recStart,
                       column_data_t *d_columnData)
{
	// thread IDs range per block, so also need the block id
	long	rec_id  = threadIdx.x + (blockDim.x * blockIdx.x);		// this is entry into the field array - tid is an elements within the num_entries array

	// we can have more threads than data, make sure we are not past the end of the data
	if ( rec_id >= num_records)
		return;

	long start 		= recStart[rec_id];
	long stop 		= recStart[rec_id + 1];

	long pos 		= start;
	int  col 		= 0;
	int  actual_col = 0;

	// Going through all the columns of a given record
	while(col<num_columns){

		if(start>stop)
			break;

		pos = seekFieldEnd(raw_csv, opts, pos, stop);

		// Checking if this is a column that the user wants --- user can filter columns
		if(parseCol[col]==true){

			long tempPos=pos-1;

			// Checking if the record is NULL
			if(start > tempPos ||
				serializedTrieContains(opts.naValuesTrie, raw_csv + start, pos - start)){
				atomicAdd(& d_columnData[actual_col].countNULL, 1L);
				pos++;
				start=pos;
				col++;
				actual_col++;
				continue;	
			}

			long countNumber=0;
			long countDecimal=0;
			long countSlash=0;
			long countDash=0;
			long countPlus=0;
			long countColon=0;
			long countString=0;
			long countExponent=0;

			// Modify start & end to ignore whitespace and quotechars
			// This could possibly result in additional empty fields
			adjustForWhitespaceAndQuotes(raw_csv, &start, &tempPos);

			const long strLen = tempPos - start + 1;

			const bool maybe_hex = ((strLen > 2 && raw_csv[start] == '0' && raw_csv[start + 1] == 'x') ||
				(strLen > 3 && raw_csv[start] == '-' && raw_csv[start + 1] == '0' && raw_csv[start + 2] == 'x'));

			for(long startPos=start; startPos<=tempPos; startPos++){
				if(isDigit(raw_csv[startPos], maybe_hex)){
					countNumber++;
					continue;
				}
				// Looking for unique characters that will help identify column types.
				switch (raw_csv[startPos]){
					case '.':
						countDecimal++;break;
					case '-':
						countDash++; break;
					case '+':
						countPlus++; break;
					case '/':
						countSlash++;break;
					case ':':
						countColon++;break;
					case 'e':
					case 'E':
						if (!maybe_hex && startPos > start && startPos < tempPos) 
							countExponent++;break;
					default:
						countString++;
						break;	
				}
			}
			const int countSign = countDash + countPlus;

			// Integers have to have the length of the string
			long int_req_number_cnt = strLen;
			// Off by one if they start with a minus sign
			if((raw_csv[start]=='-' || raw_csv[start]=='+') && strLen > 1){
				--int_req_number_cnt;
			}
			// Off by one if they are a hexadecimal number
			if(maybe_hex) {
				--int_req_number_cnt;
			}

			if(strLen==0){ // Removed spaces ' ' in the pre-processing and thus we can have an empty string.
				atomicAdd(& d_columnData[actual_col].countNULL, 1L);
			}
			else if(countNumber==int_req_number_cnt){
				// Checking to see if we the integer value requires 8,16,32,64 bits.
				// This will allow us to allocate the exact amount of memory.
				const auto value = convertStrToValue<int64_t>(raw_csv, start, tempPos, opts);
				const size_t field_len = tempPos - start + 1;
				if (serializedTrieContains(opts.trueValuesTrie, raw_csv + start, field_len) ||
						serializedTrieContains(opts.falseValuesTrie, raw_csv + start, field_len)){
					atomicAdd(& d_columnData[actual_col].countBool, 1);
				}
				else if(value >= (1L<<31)){
					atomicAdd(& d_columnData[actual_col].countInt64, 1);
				}
				else if(value >= (1L<<15)){
					atomicAdd(& d_columnData[actual_col].countInt32, 1);
				}
				else if(value >= (1L<<7)){
					atomicAdd(& d_columnData[actual_col].countInt16, 1);
				}
				else{
					atomicAdd(& d_columnData[actual_col].countInt8, 1);
				}
			}
			else if(isLikeFloat(strLen, countNumber, countDecimal, countSign, countExponent)){
					atomicAdd(& d_columnData[actual_col].countFloat, 1);
			}
			// The date-time field cannot have more than 3 strings. As such if an entry has more than 3 string characters, it is not 
			// a data-time field. Also, if a string has multiple decimals, then is not a legit number.
			else if(countString > 3 || countDecimal > 1){
				atomicAdd(& d_columnData[actual_col].countString, 1);
			}
			else {
				// A date field can have either one or two '-' or '\'. A legal combination will only have one of them.
				// To simplify the process of auto column detection, we are not covering all the date-time formation permutations.
				if((countDash>0 && countDash<=2 && countSlash==0)|| (countDash==0 && countSlash>0 && countSlash<=2) ){
					if((countColon<=2)){
						atomicAdd(& d_columnData[actual_col].countDateAndTime, 1);
					}
					else{
						atomicAdd(& d_columnData[actual_col].countString, 1);
					}
				}
				// Default field is string type.
				else{
					atomicAdd(& d_columnData[actual_col].countString, 1);
				}
			}
			actual_col++;
		}
		pos++;
		start=pos;
		col++;	

	}
}

CsvReader::Impl::Impl(csv_reader_args const &args) : args_(args) {}

table CsvReader::Impl::read_byte_range(size_t offset, size_t size) {
  byte_range_offset = offset;
  byte_range_size = size;
  return read();
}

table CsvReader::Impl::read_rows(gdf_size_type num_skip_header, gdf_size_type num_skip_footer, gdf_size_type num_rows) {
  CUDF_EXPECTS(num_rows == -1 || num_skip_footer == 0, "cannot use both num_rows and num_skip_footer parameters");

  skiprows = num_skip_header;
  nrows = num_rows;
  skipfooter = num_skip_footer;
  return read();
}

} // namespace cudf
