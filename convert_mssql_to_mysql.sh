#!/bin/bash

# MSSQL to MySQL Converter Script
# This script provides multiple methods to convert MSSQL .bak files to MySQL

BAK_FILE="$1"
OUTPUT_DIR="${2:-sqlOutput}"

if [ -z "$BAK_FILE" ]; then
    echo "Usage: $0 <input.bak> [output_directory]"
    echo "Example: $0 'Children ES 3.12.2025.bak' sqlOutput"
    exit 1
fi

if [ ! -f "$BAK_FILE" ]; then
    echo "Error: File '$BAK_FILE' not found"
    exit 1
fi

echo "==================================="
echo "MSSQL to MySQL Converter"
echo "==================================="
echo "Input file: $BAK_FILE"
echo "Output directory: $OUTPUT_DIR"
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    echo "❌ Docker is not running!"
    echo ""
    echo "Please start Docker Desktop and try again."
    echo ""
    echo "Alternative methods:"
    echo "1. Use a Windows machine with SQL Server installed"
    echo "2. Use online conversion tools"
    echo "3. Use SQL Server Management Studio (SSMS) to export data"
    echo ""
    exit 1
fi

echo "✓ Docker is running"
echo ""

# Configuration
CONTAINER_NAME="mssql_converter_$$"
SA_PASSWORD="YourStrong@Passw0rd123"
DB_NAME="RestoredDB"
WORK_DIR=$(pwd)
BAK_DIR=$(dirname "$(realpath "$BAK_FILE")")
BAK_FILENAME=$(basename "$BAK_FILE")

echo "Starting MSSQL Server container..."
docker run -d \
    --name "$CONTAINER_NAME" \
    --platform linux/amd64 \
    -e "ACCEPT_EULA=Y" \
    -e "MSSQL_SA_PASSWORD=$SA_PASSWORD" \
    -p 1433:1433 \
    -v "$BAK_DIR:/backup" \
    mcr.microsoft.com/mssql/server:2022-latest

if [ $? -ne 0 ]; then
    echo "❌ Failed to start Docker container"
    exit 1
fi

echo "✓ Container started: $CONTAINER_NAME"
echo "Waiting for SQL Server to initialize (40 seconds)..."
sleep 40

# Function to cleanup
cleanup() {
    echo ""
    echo "Cleaning up..."
    docker stop "$CONTAINER_NAME" > /dev/null 2>&1
    docker rm "$CONTAINER_NAME" > /dev/null 2>&1
    echo "✓ Cleanup complete"
}

trap cleanup EXIT

# Get logical file names from backup
echo ""
echo "Reading backup file information..."
docker exec "$CONTAINER_NAME" /opt/mssql-tools18/bin/sqlcmd \
    -S localhost -U SA -P "$SA_PASSWORD" -C \
    -Q "RESTORE FILELISTONLY FROM DISK = '/backup/$BAK_FILENAME'" \
    > "$OUTPUT_DIR/filelistonly.txt"

if [ $? -ne 0 ]; then
    echo "❌ Failed to read backup file"
    cat "$OUTPUT_DIR/filelistonly.txt"
    exit 1
fi

# Extract logical names - parse the filelistonly output properly
# Look for lines with 'D' (Data) and 'L' (Log) file types
DATA_FILE=$(awk '/^[A-Za-z]/ && / D / {print $1; exit}' "$OUTPUT_DIR/filelistonly.txt")
LOG_FILE=$(awk '/^[A-Za-z]/ && / L / {print $1; exit}' "$OUTPUT_DIR/filelistonly.txt")

# Fallback if parsing failed
if [ -z "$DATA_FILE" ]; then
    DATA_FILE="ChildrenDB"
    LOG_FILE="ChildrenDB_log"
    echo "⚠ Using default logical names: $DATA_FILE, $LOG_FILE"
else
    echo "✓ Detected logical names: Data='$DATA_FILE', Log='$LOG_FILE'"
fi

# Restore database
echo ""
echo "Restoring database..."
docker exec "$CONTAINER_NAME" /opt/mssql-tools18/bin/sqlcmd \
    -S localhost -U SA -P "$SA_PASSWORD" -C \
    -Q "RESTORE DATABASE [$DB_NAME] FROM DISK = '/backup/$BAK_FILENAME' WITH MOVE '$DATA_FILE' TO '/var/opt/mssql/data/${DB_NAME}.mdf', MOVE '$LOG_FILE' TO '/var/opt/mssql/data/${DB_NAME}_log.ldf', REPLACE" \
    > "$OUTPUT_DIR/restore.log" 2>&1

if [ $? -ne 0 ]; then
    echo "❌ Database restore failed"
    cat "$OUTPUT_DIR/restore.log"
    exit 1
fi

echo "✓ Database restored successfully"

# Export schema
echo ""
echo "Exporting database schema..."
docker exec "$CONTAINER_NAME" /opt/mssql-tools18/bin/sqlcmd \
    -S localhost -U SA -P "$SA_PASSWORD" -C -d "$DB_NAME" \
    -Q "SELECT TABLE_SCHEMA, TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME" \
    -o "$OUTPUT_DIR/tables_list.txt" -h -1 -W

# Get table count
TABLE_COUNT=$(grep -v "^$" "$OUTPUT_DIR/tables_list.txt" | grep -v "TABLE_SCHEMA" | grep -v "^-" | wc -l | tr -d ' ')
echo "✓ Found $TABLE_COUNT tables"

# Generate MySQL schema script
echo ""
echo "Generating MySQL conversion script..."
python3 - "$CONTAINER_NAME" "$SA_PASSWORD" "$DB_NAME" "$OUTPUT_DIR" << 'PYTHON_SCRIPT'
import sys
import subprocess
import re

container = sys.argv[1]
password = sys.argv[2]
db_name = sys.argv[3]
output_dir = sys.argv[4]

def run_query(query, db=None):
    cmd = ['docker', 'exec', container, '/opt/mssql-tools18/bin/sqlcmd',
           '-S', 'localhost', '-U', 'SA', '-P', password, '-C']
    if db:
        cmd.extend(['-d', db])
    cmd.extend(['-Q', query, '-h', '-1', '-W', '-s', '|'])

    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.stdout

def escape_sql_value(value):
    """Escape values for MySQL INSERT statements"""
    if value is None or value.strip() == '' or value.strip().upper() == 'NULL':
        return 'NULL'
    # Escape single quotes and backslashes
    value = value.replace('\\', '\\\\').replace("'", "''")
    return f"'{value}'"

def convert_type(mssql_type, length, precision, scale):
    mssql_type = mssql_type.lower()

    type_map = {
        'int': 'INT',
        'bigint': 'BIGINT',
        'smallint': 'SMALLINT',
        'tinyint': 'TINYINT',
        'bit': 'TINYINT(1)',
        'decimal': f'DECIMAL({precision},{scale})' if precision else 'DECIMAL(10,2)',
        'numeric': f'DECIMAL({precision},{scale})' if precision else 'DECIMAL(10,2)',
        'money': 'DECIMAL(19,4)',
        'smallmoney': 'DECIMAL(10,4)',
        'float': 'DOUBLE',
        'real': 'FLOAT',
        'datetime': 'DATETIME',
        'datetime2': 'DATETIME',
        'smalldatetime': 'DATETIME',
        'date': 'DATE',
        'time': 'TIME',
        'char': f'CHAR({length})' if length and length > 0 else 'CHAR(1)',
        'varchar': f'VARCHAR({length})' if length and 0 < length < 65535 else 'TEXT',
        'nchar': f'CHAR({length})' if length and length > 0 else 'CHAR(1)',
        'nvarchar': f'VARCHAR({length})' if length and 0 < length < 65535 else 'TEXT',
        'text': 'TEXT',
        'ntext': 'TEXT',
        'binary': 'BLOB',
        'varbinary': 'BLOB',
        'image': 'BLOB',
        'uniqueidentifier': 'CHAR(36)',
        'xml': 'TEXT'
    }

    return type_map.get(mssql_type, 'VARCHAR(255)')

# Get tables
tables_query = """SELECT TABLE_SCHEMA, TABLE_NAME
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_TYPE = 'BASE TABLE'
ORDER BY TABLE_NAME"""

tables_output = run_query(tables_query, db_name)
tables = []
for line in tables_output.strip().split('\n'):
    parts = [p.strip() for p in line.split('|')]
    if len(parts) >= 2 and parts[0] and parts[0] != 'TABLE_SCHEMA':
        tables.append((parts[0], parts[1]))

print(f"Processing {len(tables)} tables...")

# Start MySQL script
mysql_lines = []
mysql_lines.append("-- MySQL Database Conversion")
mysql_lines.append(f"-- Source: MSSQL Database")
mysql_lines.append(f"-- Tables: {len(tables)}")
mysql_lines.append("")
mysql_lines.append("SET FOREIGN_KEY_CHECKS=0;")
mysql_lines.append("SET SQL_MODE = 'NO_AUTO_VALUE_ON_ZERO';")
mysql_lines.append("SET time_zone = '+00:00';")
mysql_lines.append("")

for schema, table in tables:
    print(f"  Processing: {table}...")

    # Get columns
    cols_query = f"""SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH,
    NUMERIC_PRECISION, NUMERIC_SCALE, IS_NULLABLE, COLUMN_DEFAULT
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA='{schema}' AND TABLE_NAME='{table}'
    ORDER BY ORDINAL_POSITION"""

    cols_output = run_query(cols_query, db_name)

    mysql_lines.append(f"-- Table: {table}")
    mysql_lines.append(f"DROP TABLE IF EXISTS `{table}`;")
    mysql_lines.append(f"CREATE TABLE `{table}` (")

    column_defs = []
    column_names = []
    for line in cols_output.strip().split('\n'):
        parts = [p.strip() for p in line.split('|')]
        if len(parts) >= 6 and parts[0] and parts[0] != 'COLUMN_NAME':
            col_name = parts[0]
            data_type = parts[1]
            max_length = int(parts[2]) if parts[2] and parts[2] != 'NULL' else None
            precision = int(parts[3]) if parts[3] and parts[3] != 'NULL' else None
            scale = int(parts[4]) if parts[4] and parts[4] != 'NULL' else None
            is_nullable = parts[5]

            mysql_type = convert_type(data_type, max_length, precision, scale)
            nullable = "NULL" if is_nullable == 'YES' else "NOT NULL"

            column_defs.append(f"  `{col_name}` {mysql_type} {nullable}")
            column_names.append(col_name)

    mysql_lines.append(",\n".join(column_defs))
    mysql_lines.append(") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;")
    mysql_lines.append("")

    # Get row count
    count_query = f"SELECT COUNT(*) FROM [{schema}].[{table}]"
    count_output = run_query(count_query, db_name)
    row_count = 0
    for line in count_output.strip().split('\n'):
        line = line.strip()
        if line and line.isdigit():
            row_count = int(line)
            break

    if row_count > 0:
        print(f"    Exporting {row_count} rows...")

        # Get data
        data_query = f"SELECT * FROM [{schema}].[{table}]"
        data_output = run_query(data_query, db_name)

        data_lines = data_output.strip().split('\n')
        insert_values = []

        for line in data_lines:
            parts = [p.strip() for p in line.split('|')]
            # Filter out header/separator lines
            if len(parts) >= len(column_names) and parts[0] not in ['', column_names[0]]:
                # Take only as many columns as we have defined
                values = [escape_sql_value(parts[i]) if i < len(parts) else 'NULL'
                         for i in range(len(column_names))]
                insert_values.append(f"  ({', '.join(values)})")

        if insert_values:
            mysql_lines.append(f"-- Data for table: {table} ({len(insert_values)} rows)")
            mysql_lines.append(f"INSERT INTO `{table}` (`{'`, `'.join(column_names)}`) VALUES")
            mysql_lines.append(",\n".join(insert_values) + ";")
            mysql_lines.append("")
    else:
        print(f"    Table is empty")
        mysql_lines.append(f"-- No data for table: {table}")
        mysql_lines.append("")

mysql_lines.append("SET FOREIGN_KEY_CHECKS=1;")

# Write schema file
output_file = f"{output_dir}/mysql_schema.sql"
with open(output_file, 'w', encoding='utf-8') as f:
    f.write('\n'.join(mysql_lines))

print(f"\n✓ Schema exported to: {output_file}")
print(f"✓ Data files exported to: {output_dir}/")
PYTHON_SCRIPT

echo ""
echo "========================================="
echo "✓ Conversion Complete!"
echo "========================================="
echo "Output location: $OUTPUT_DIR/"
echo ""
echo "Files generated:"
ls -lh "$OUTPUT_DIR/"
echo ""
echo "To import into MySQL:"
echo "  mysql -u root -p your_database < $OUTPUT_DIR/mysql_schema.sql"
echo ""
