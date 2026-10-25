const { spawnSync } = require("node:child_process");
const path = require("node:path");
const fs = require("node:fs");
const root = path.resolve(__dirname, "../..");
if (process.platform !== "darwin") { console.error("Safari packaging needs macOS and Xcode."); process.exit(1); }
const output = path.join(root, "build", "safari");
const project = path.join(output, 'OpenRead', 'OpenRead.xcodeproj');
if (fs.existsSync(project) && !process.argv.includes('--refresh')) {
  console.log("Safari project already exists at build/safari/OpenRead. Use npm run safari -- --refresh after adding extension files.");
  process.exit(0);
}
fs.mkdirSync(output, { recursive: true });
let tool = "safari-web-extension-packager";
if (spawnSync("xcrun", ["--find", tool], { stdio: "ignore" }).status !== 0) tool = "safari-web-extension-converter";
// Match the parent identifier Apple's packager derives from the app name.
const args = fs.existsSync(project)
  ? [tool, '--rebuild-project', project, '--macos-only', '--no-open', '--no-prompt', '--force']
  : [tool, path.join(root, "extension"), "--project-location", output, "--app-name", "OpenRead", "--bundle-identifier", "dev.openread.OpenRead", "--swift", "--macos-only", "--no-open", "--no-prompt"];
const result = spawnSync("xcrun", args, { stdio: "inherit" });
process.exit(result.status ?? 1);
