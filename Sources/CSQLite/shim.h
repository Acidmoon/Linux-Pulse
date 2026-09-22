/* SQLite, for hosts that have no modulemap of their own.
 *
 * Darwin's SDK declares a `SQLite3` module, so `import SQLite3` works there.
 * The Linux Swift toolchain does not: `swiftc -typecheck` on `import SQLite3`
 * fails with "no such module" even with libsqlite3-dev installed, because
 * nothing in the toolchain ships a modulemap for it.
 *
 * The header is reached through a shim rather than named by absolute path so
 * that a distribution putting it somewhere other than /usr/include still
 * works.
 *
 * Sources import it as:
 *
 *     #if canImport(SQLite3)
 *     import SQLite3
 *     #else
 *     import CSQLite
 *     #endif
 *
 * so macOS keeps using its own module and this exists only to fill the gap.
 */
#include <sqlite3.h>
