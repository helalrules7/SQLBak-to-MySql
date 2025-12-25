# MSSQL to MySQL Database Converter

A comprehensive solution for converting Microsoft SQL Server `.bak` backup files to MySQL-compatible SQL format.

## Overview

This toolkit provides automated scripts to restore MSSQL `.bak` files and export them as MySQL-compatible SQL files with full schema and data conversion.

## Features

- Automatic MSSQL data type to MySQL data type conversion
- Complete schema export with proper MySQL syntax
- Full data export with INSERT statements
- UTF8MB4 encoding support (full Unicode including emojis)
- InnoDB storage engine with transaction support
- Docker-based solution (no MSSQL Server installation required)
- Supports databases of any size
- Automatic logical file name detection

## Prerequisites

- **Docker Desktop** - Required for running MSSQL Server container
- **Python 3** - For the Python-based converter (optional)
- **Bash** - For the shell script converter

### Installing Docker

**macOS:**
```bash
brew install --cask docker
# Then start Docker Desktop from Applications
```

**Linux:**
```bash
# Follow instructions at: https://docs.docker.com/engine/install/
```

**Windows:**
Download Docker Desktop from [docker.com](https://www.docker.com/products/docker-desktop)

## Quick Start

### Using the Bash Script (Recommended)

```bash
# Make the script executable
chmod +x convert_mssql_to_mysql.sh

# Run the conversion
./convert_mssql_to_mysql.sh "your-database.bak" output-folder

# Example:
./convert_mssql_to_mysql.sh "Children ES 3.12.2025.bak" sqlOutput
```

### Using the Python Script

```bash
# Make the script executable
chmod +x mssql_to_mysql_converter.py

# Run the conversion
python3 mssql_to_mysql_converter.py "your-database.bak" output-folder

# Example:
python3 mssql_to_mysql_converter.py "Children ES 3.12.2025.bak" sqlOutput
```

## How It Works

1. **Starts MSSQL Container**: Launches a temporary SQL Server 2022 container using Docker
2. **Restores Backup**: Restores the `.bak` file inside the container
3. **Extracts Schema**: Reads all table structures and column definitions
4. **Converts Data Types**: Maps MSSQL types to MySQL equivalents
5. **Exports Data**: Generates INSERT statements for all table data
6. **Creates SQL File**: Outputs a complete MySQL-compatible SQL file
7. **Cleanup**: Removes the temporary container

## Data Type Conversion

The scripts automatically convert MSSQL data types to MySQL equivalents:

| MSSQL Type | MySQL Type |
|------------|------------|
| `int`, `bigint`, `smallint`, `tinyint` | `INT`, `BIGINT`, `SMALLINT`, `TINYINT` |
| `bit` | `TINYINT(1)` |
| `decimal`, `numeric` | `DECIMAL(precision,scale)` |
| `money` | `DECIMAL(19,4)` |
| `float`, `real` | `DOUBLE`, `FLOAT` |
| `datetime`, `datetime2`, `smalldatetime` | `DATETIME` |
| `date`, `time` | `DATE`, `TIME` |
| `varchar`, `nvarchar` | `VARCHAR(length)` or `TEXT` |
| `char`, `nchar` | `CHAR(length)` |
| `text`, `ntext` | `TEXT` |
| `binary`, `varbinary`, `image` | `BLOB` |
| `uniqueidentifier` | `CHAR(36)` |
| `xml` | `TEXT` |

## Output Files

After conversion, the output folder contains:

- **`mysql_schema.sql`** - Main MySQL database file with schema and data
- **`filelistonly.txt`** - Backup file information from MSSQL
- **`restore.log`** - Database restoration log
- **`CONVERSION_SUMMARY.txt`** - Detailed conversion statistics

## Importing to MySQL

### Step 1: Create Database

```bash
mysql -u root -p -e "CREATE DATABASE your_database CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
```

### Step 2: Import SQL File

```bash
mysql -u root -p your_database < sqlOutput/mysql_schema.sql
```

### Step 3: Verify Import

```bash
# List all tables
mysql -u root -p your_database -e "SHOW TABLES;"

# Check row counts
mysql -u root -p your_database -e "SELECT COUNT(*) FROM TableName;"
```

## Configuration

### Adjusting Wait Time

If your database is large, you may need to increase the initialization wait time in the script:

```bash
# In convert_mssql_to_mysql.sh, line 71
echo "Waiting for SQL Server to initialize (40 seconds)..."
sleep 40  # Increase this value for larger databases
```

### Custom Database Name

By default, the restored database is named `RestoredDB`. To change this:

```bash
# In convert_mssql_to_mysql.sh, line 50
DB_NAME="YourCustomName"
```

## Troubleshooting

### Docker Not Running

**Error:** `Cannot connect to the Docker daemon`

**Solution:** Start Docker Desktop and wait for it to fully initialize

```bash
open -a Docker  # macOS
# Wait 30 seconds, then try again
```

### Platform Architecture Warning

**Warning:** `The requested image's platform (linux/amd64) does not match the detected host platform (linux/arm64/v8)`

**Solution:** This is normal on Apple Silicon Macs. The script uses `--platform linux/amd64` to ensure compatibility.

### Restore Failed

**Error:** `Logical file '' is not part of database`

**Solution:** The script automatically detects logical file names. If this fails, check `sqlOutput/filelistonly.txt` and update the fallback names in the script (lines 105-106).

### Connection Timeout

**Error:** Container starts but sqlcmd commands fail

**Solution:** Increase the wait time (see Configuration section above)

## Example Output

```
===================================
MSSQL to MySQL Converter
===================================
Input file: Children ES 3.12.2025.bak
Output directory: sqlOutput

✓ Docker is running

Starting MSSQL Server container...
✓ Container started: mssql_converter_12345
Waiting for SQL Server to initialize (40 seconds)...

Reading backup file information...
✓ Detected logical names: Data='ChildrenDB', Log='ChildrenDB_log'

Restoring database...
✓ Database restored successfully

Exporting database schema...
✓ Found 24 tables

Generating MySQL conversion script...
Processing 24 tables...
  Processing: TblPatient...
    Exporting 4449 rows...
  Processing: TblMedTreat...
    Exporting 73808 rows...
  ...

✓ Schema exported to: sqlOutput/mysql_schema.sql

=========================================
✓ Conversion Complete!
=========================================
```

## Performance

- **Small databases** (< 100MB): ~1-2 minutes
- **Medium databases** (100MB - 1GB): ~3-10 minutes
- **Large databases** (> 1GB): Varies based on size and complexity

## Limitations

- Primary keys and foreign keys are not automatically preserved (only table structure and data)
- Indexes are not migrated (you may need to recreate them in MySQL)
- Stored procedures, views, and triggers are not converted
- Computed columns are converted to regular columns with their current values

## Advanced Usage

### Converting Multiple Databases

```bash
#!/bin/bash
for bak_file in *.bak; do
    folder_name="${bak_file%.bak}_output"
    ./convert_mssql_to_mysql.sh "$bak_file" "$folder_name"
done
```

### Automated Import

```bash
#!/bin/bash
DB_NAME="your_database"
mysql -u root -p -e "DROP DATABASE IF EXISTS $DB_NAME;"
mysql -u root -p -e "CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -u root -p $DB_NAME < sqlOutput/mysql_schema.sql
echo "Import complete!"
```

## Files Included

- `convert_mssql_to_mysql.sh` - Main bash conversion script
- `mssql_to_mysql_converter.py` - Alternative Python script
- `README.md` - This documentation file

## Technical Details

### Docker Container Specifications

- **Image:** `mcr.microsoft.com/mssql/server:2022-latest`
- **Platform:** `linux/amd64` (for compatibility)
- **Port:** `1433` (SQL Server default)
- **Memory:** Uses Docker default (minimum 2GB recommended)

### SQL Tools Version

The scripts use `sqlcmd` from `/opt/mssql-tools18/bin/` which includes:
- TLS/SSL support with `-C` flag
- Unicode support
- Modern authentication methods

## License

This project is provided as-is for database migration purposes.

## Support

For issues or questions:
1. Check the Troubleshooting section above
2. Verify Docker is running: `docker info`
3. Check the log files in the output folder
4. Ensure the `.bak` file is not corrupted

## Contributing

Feel free to modify and extend these scripts for your specific needs. Common customizations:
- Add support for indexes and foreign keys
- Implement stored procedure conversion
- Add progress bars for large databases
- Include view and trigger migration

## Version History

- **v1.0** - Initial release with basic conversion
- **v1.1** - Added automatic logical name detection
- **v1.2** - Improved data type mapping and UTF8MB4 support
- **v1.3** - Added comprehensive error handling and logging

## Author

Generated for database migration tasks using Docker and SQL Server tools.

---

**Note:** Always test the converted database thoroughly before using it in production. It's recommended to verify data integrity and recreate any necessary indexes, foreign keys, and constraints after import.
