"""Never let backend tests inherit the development database connection."""

import os

# Set before any app imports, including existing test modules. Route integration
# fixtures supply their own disposable database via get_db overrides.
os.environ["DATABASE_URL"] = "sqlite+pysqlite:///:memory:"
