// Deviation from the task brief's original `node:fs`-based draft: this file
// runs inside the miniflare/workerd test sandbox (not host Node.js), whose
// `node:fs` (via the `nodejs_compat` shim) only exposes a synthetic
// filesystem (`/bundle`, `/tmp`, `/dev`) — the same restriction real
// deployed Workers have. `readdirSync(join(__dirname, "..", "..",
// "migrations"))` therefore throws ENOENT there even though the directory
// exists on disk (confirmed empirically: `readdirSync("/")` inside a test
// returns only `['bundle', 'tmp', 'dev']`). Vite's `import.meta.glob` reads
// the files at bundle time (in the real Node.js/Vite process, before the
// code ever reaches workerd) and inlines their contents as strings, so it
// has the same "read every migrations/*.sql file" effect without a runtime
// disk read.
//
// Second deviation from the brief's draft: the brief's statement splitter
// (`sql.split(";")` then dropping any resulting chunk that *starts* with
// "--") mis-parses 0001_accounts.sql. Its leading `-- 0001_accounts: ...`
// comment line has no semicolon before the `CREATE TABLE accounts (...)`
// that follows it on the very next line, so both land in the same
// pre-split chunk; since that chunk's trimmed text starts with "--", the
// whole chunk — comment AND the `accounts` table DDL — was silently
// dropped (`account_devices` and its index, which sit in later chunks that
// don't start with "--", were still created — SQLite doesn't validate a
// `REFERENCES` target at CREATE TABLE time). Confirmed empirically: with
// the brief's exact splitter, `SELECT * FROM accounts` fails with
// "no such table: accounts" even on the first spec. Fix: strip full-line
// `--` comments before splitting on ";", so a comment can never fuse with
// the statement after it.
const migrationModules = import.meta.glob<string>("../../migrations/*.sql", {
  eager: true,
  query: "?raw",
  import: "default",
});

/** Apply every migrations/*.sql file (sorted) to a miniflare D1 binding. */
export async function applyMigrations(db: D1Database): Promise<void> {
  const files = Object.keys(migrationModules).sort();
  for (const f of files) {
    const sql = migrationModules[f];
    const withoutComments = sql
      .split("\n")
      .filter((line) => !line.trim().startsWith("--"))
      .join("\n");
    const statements = withoutComments.split(";").map((s) => s.trim()).filter((s) => s.length > 0);
    for (const stmt of statements) {
      await db.prepare(stmt).run();
    }
  }
}
