import Mocha from "mocha";
import * as path from "path";
import * as fs from "fs";

/**
 * Mocha test runner bootstrap for VS Code extension test infrastructure.
 * Can be invoked via `node dist/test/suite/index.js` or through VS Code's
 * extension test runner.
 */
export function run(): Promise<void> {
  const mocha = new Mocha({ ui: "bdd", color: true, timeout: 5000 });
  const testsRoot = path.resolve(__dirname, "..");

  return new Promise((resolve, reject) => {
    try {
      const files = fs.readdirSync(testsRoot).filter((f) => f.endsWith(".test.js"));
      for (const f of files) {
        mocha.addFile(path.join(testsRoot, f));
      }
      mocha.run((failures) => {
        if (failures > 0) {
          reject(new Error(`${failures} test(s) failed`));
        } else {
          resolve();
        }
      });
    } catch (e) {
      reject(e);
    }
  });
}

if (require.main === module) {
  run().then(
    () => process.exit(0),
    () => process.exit(1)
  );
}
