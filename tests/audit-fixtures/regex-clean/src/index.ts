const pattern = /require("missing")/;
const another = /import("also-missing")/g;

function f() {
  return /require("return-missing")/;
}

if (condition) /require("if-missing")/.test(value);
