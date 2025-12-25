#!/usr/bin/env python3
"""
Microsoft SQL Server BAK to MySQL Converter
This script extracts data from MSSQL .bak files and converts it to MySQL format.
"""

import os
import sys
import subprocess
import tempfile
import shutil
from pathlib import Path

class MSSQLToMySQLConverter:
    def __init__(self, bak_file, output_dir):
        self.bak_file = Path(bak_file)
        self.output_dir = Path(output_dir)
        self.temp_dir = None

        if not self.bak_file.exists():
            raise FileNotFoundError(f"BAK file not found: {self.bak_file}")

    def check_dependencies(self):
        """Check if required tools are installed"""
        print("Checking dependencies...")

        dependencies = {
            'docker': 'Docker is required for MSSQL restoration',
            'mysqldump': 'MySQL client tools are required (optional, for verification)'
        }

        missing = []
        for cmd, desc in dependencies.items():
            if shutil.which(cmd) is None:
                if cmd == 'docker':
                    missing.append(f"  - {cmd}: {desc}")

        if missing:
            print("\nMissing dependencies:")
            for dep in missing:
                print(dep)
            print("\nTo install Docker:")
            print("  macOS: brew install --cask docker")
            print("  Linux: https://docs.docker.com/engine/install/")
            return False

        print("✓ All required dependencies found")
        return True

    def restore_mssql_backup(self):
        """Restore MSSQL .bak file using Docker"""
        print(f"\nRestoring MSSQL backup: {self.bak_file}")

        self.temp_dir = tempfile.mkdtemp()
        container_name = "mssql_converter"
        password = "YourStrong@Passw0rd"

        try:
            # Stop and remove existing container if it exists
            subprocess.run(['docker', 'stop', container_name],
                         stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
            subprocess.run(['docker', 'rm', container_name],
                         stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)

            # Start MSSQL container
            print("Starting MSSQL Docker container...")
            subprocess.run([
                'docker', 'run', '-d',
                '--name', container_name,
                '-e', 'ACCEPT_EULA=Y',
                '-e', f'SA_PASSWORD={password}',
                '-p', '1433:1433',
                '-v', f'{self.bak_file.parent}:/backup',
                'mcr.microsoft.com/mssql/server:2019-latest'
            ], check=True)

            # Wait for MSSQL to start
            print("Waiting for MSSQL to initialize (30 seconds)...")
            import time
            time.sleep(30)

            # Get logical names from backup
            print("Reading backup file information...")
            result = subprocess.run([
                'docker', 'exec', container_name,
                '/opt/mssql-tools/bin/sqlcmd', '-S', 'localhost',
                '-U', 'SA', '-P', password,
                '-Q', f"RESTORE FILELISTONLY FROM DISK = '/backup/{self.bak_file.name}'"
            ], capture_output=True, text=True)

            if result.returncode != 0:
                print(f"Error reading backup: {result.stderr}")
                return None

            # Parse logical names (simplified - may need adjustment)
            lines = result.stdout.strip().split('\n')
            logical_names = []
            for line in lines[2:]:  # Skip header lines
                parts = line.split()
                if parts:
                    logical_names.append(parts[0])

            if len(logical_names) < 2:
                # Fallback to common names
                logical_names = ['ChildrenES', 'ChildrenES_log']

            data_file = logical_names[0]
            log_file = logical_names[1] if len(logical_names) > 1 else logical_names[0] + '_log'

            # Restore database
            print(f"Restoring database with logical names: {data_file}, {log_file}")
            db_name = "RestoredDB"
            restore_cmd = f"""RESTORE DATABASE [{db_name}]
FROM DISK = '/backup/{self.bak_file.name}'
WITH MOVE '{data_file}' TO '/var/opt/mssql/data/{db_name}.mdf',
     MOVE '{log_file}' TO '/var/opt/mssql/data/{db_name}_log.ldf',
     REPLACE"""

            result = subprocess.run([
                'docker', 'exec', container_name,
                '/opt/mssql-tools/bin/sqlcmd', '-S', 'localhost',
                '-U', 'SA', '-P', password,
                '-Q', restore_cmd
            ], capture_output=True, text=True)

            if result.returncode != 0:
                print(f"Restore failed: {result.stderr}")
                return None

            print("✓ Database restored successfully")
            return {'container': container_name, 'password': password, 'db_name': db_name}

        except subprocess.CalledProcessError as e:
            print(f"Error: {e}")
            return None

    def export_to_sql(self, db_info):
        """Export MSSQL database to SQL scripts"""
        print("\nExporting database schema and data...")

        self.output_dir.mkdir(parents=True, exist_ok=True)

        container = db_info['container']
        password = db_info['password']
        db_name = db_info['db_name']

        # Get list of tables
        result = subprocess.run([
            'docker', 'exec', container,
            '/opt/mssql-tools/bin/sqlcmd', '-S', 'localhost',
            '-U', 'SA', '-P', password, '-d', db_name,
            '-Q', "SELECT TABLE_SCHEMA, TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE'",
            '-h', '-1', '-W'
        ], capture_output=True, text=True)

        if result.returncode != 0:
            print(f"Error getting tables: {result.stderr}")
            return False

        # Parse tables
        tables = []
        for line in result.stdout.strip().split('\n'):
            parts = line.strip().split()
            if len(parts) >= 2 and parts[0] not in ['TABLE_SCHEMA', '']:
                schema = parts[0]
                table = parts[1]
                tables.append((schema, table))

        print(f"Found {len(tables)} tables")

        # Export schema and data for each table
        mysql_script = []
        mysql_script.append("-- MySQL Database Export")
        mysql_script.append(f"-- Converted from: {self.bak_file.name}")
        mysql_script.append(f"-- Date: {subprocess.getoutput('date')}\n")
        mysql_script.append("SET FOREIGN_KEY_CHECKS=0;")
        mysql_script.append("SET SQL_MODE = 'NO_AUTO_VALUE_ON_ZERO';")
        mysql_script.append("SET time_zone = '+00:00';\n")

        for schema, table in tables:
            print(f"  Exporting {schema}.{table}...")
            full_table_name = f"[{schema}].[{table}]"

            # Get table schema
            schema_result = subprocess.run([
                'docker', 'exec', container,
                '/opt/mssql-tools/bin/sqlcmd', '-S', 'localhost',
                '-U', 'SA', '-P', password, '-d', db_name,
                '-Q', f"SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='{schema}' AND TABLE_NAME='{table}' ORDER BY ORDINAL_POSITION",
                '-h', '-1', '-W'
            ], capture_output=True, text=True)

            # Convert to MySQL CREATE TABLE
            mysql_script.append(f"\n-- Table: {table}")
            mysql_script.append(f"DROP TABLE IF EXISTS `{table}`;")
            mysql_script.append(f"CREATE TABLE `{table}` (")

            columns = []
            for col_line in schema_result.stdout.strip().split('\n'):
                parts = col_line.strip().split()
                if len(parts) >= 3 and parts[0] not in ['COLUMN_NAME', '']:
                    col_name = parts[0]
                    data_type = parts[1]
                    max_length = parts[2] if len(parts) > 2 else None
                    is_nullable = parts[3] if len(parts) > 3 else 'YES'

                    # Convert MSSQL types to MySQL types
                    mysql_type = self.convert_data_type(data_type, max_length)
                    nullable = "" if is_nullable == 'YES' else "NOT NULL"

                    columns.append(f"  `{col_name}` {mysql_type} {nullable}")

            mysql_script.append(",\n".join(columns))
            mysql_script.append(") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;\n")

            # Get table data
            data_result = subprocess.run([
                'docker', 'exec', container,
                '/opt/mssql-tools/bin/sqlcmd', '-S', 'localhost',
                '-U', 'SA', '-P', password, '-d', db_name,
                '-Q', f"SELECT * FROM {full_table_name}",
                '-s', '|', '-W'
            ], capture_output=True, text=True)

            if data_result.stdout.strip():
                data_lines = data_result.stdout.strip().split('\n')
                if len(data_lines) > 2:  # Has data beyond headers
                    mysql_script.append(f"-- Data for table: {table}")
                    mysql_script.append(f"INSERT INTO `{table}` VALUES")
                    # Note: This is simplified - proper escaping needed for production
                    values = []
                    for line in data_lines[2:]:  # Skip header lines
                        if line.strip() and not line.startswith('('):
                            cols = [f"'{c.strip()}'" if c.strip() and c.strip() != 'NULL' else 'NULL'
                                   for c in line.split('|')]
                            values.append(f"  ({', '.join(cols)})")
                    mysql_script.append(",\n".join(values) + ";\n")

        mysql_script.append("\nSET FOREIGN_KEY_CHECKS=1;")

        # Write to file
        output_file = self.output_dir / f"{self.bak_file.stem}_mysql.sql"
        with open(output_file, 'w', encoding='utf-8') as f:
            f.write('\n'.join(mysql_script))

        print(f"\n✓ Export completed: {output_file}")
        return True

    def convert_data_type(self, mssql_type, max_length):
        """Convert MSSQL data types to MySQL equivalents"""
        type_map = {
            'int': 'INT',
            'bigint': 'BIGINT',
            'smallint': 'SMALLINT',
            'tinyint': 'TINYINT',
            'bit': 'TINYINT(1)',
            'decimal': 'DECIMAL',
            'numeric': 'DECIMAL',
            'money': 'DECIMAL(19,4)',
            'smallmoney': 'DECIMAL(10,4)',
            'float': 'DOUBLE',
            'real': 'FLOAT',
            'datetime': 'DATETIME',
            'datetime2': 'DATETIME',
            'smalldatetime': 'DATETIME',
            'date': 'DATE',
            'time': 'TIME',
            'timestamp': 'TIMESTAMP',
            'char': f'CHAR({max_length})' if max_length and max_length != '-1' else 'CHAR(255)',
            'varchar': f'VARCHAR({max_length})' if max_length and max_length != '-1' else 'TEXT',
            'nchar': f'CHAR({max_length})' if max_length and max_length != '-1' else 'CHAR(255)',
            'nvarchar': f'VARCHAR({max_length})' if max_length and max_length != '-1' else 'TEXT',
            'text': 'TEXT',
            'ntext': 'TEXT',
            'binary': 'BLOB',
            'varbinary': 'BLOB',
            'image': 'BLOB',
            'uniqueidentifier': 'CHAR(36)',
            'xml': 'TEXT'
        }

        return type_map.get(mssql_type.lower(), 'VARCHAR(255)')

    def cleanup(self, db_info=None):
        """Cleanup temporary resources"""
        print("\nCleaning up...")

        if db_info:
            try:
                subprocess.run(['docker', 'stop', db_info['container']],
                             stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
                subprocess.run(['docker', 'rm', db_info['container']],
                             stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
            except:
                pass

        if self.temp_dir and os.path.exists(self.temp_dir):
            shutil.rmtree(self.temp_dir)

    def convert(self):
        """Main conversion process"""
        print(f"=== MSSQL to MySQL Converter ===")
        print(f"Input: {self.bak_file}")
        print(f"Output: {self.output_dir}\n")

        if not self.check_dependencies():
            return False

        db_info = None
        try:
            db_info = self.restore_mssql_backup()
            if not db_info:
                print("Failed to restore MSSQL backup")
                return False

            if not self.export_to_sql(db_info):
                print("Failed to export database")
                return False

            print("\n✓ Conversion completed successfully!")
            return True

        except Exception as e:
            print(f"\nError during conversion: {e}")
            import traceback
            traceback.print_exc()
            return False
        finally:
            self.cleanup(db_info)


def main():
    if len(sys.argv) < 3:
        print("Usage: python mssql_to_mysql_converter.py <input.bak> <output_directory>")
        print("Example: python mssql_to_mysql_converter.py database.bak ./sqlOutput")
        sys.exit(1)

    bak_file = sys.argv[1]
    output_dir = sys.argv[2]

    converter = MSSQLToMySQLConverter(bak_file, output_dir)
    success = converter.convert()

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
