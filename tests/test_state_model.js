const fs = require("fs")
const path = require("path")
const vm = require("vm")

const source = fs.readFileSync(path.join(__dirname, "..", "plugin", "StateModel.js"), "utf8")
  .replace(/^\.pragma library\s*/m, "")
const context = {}
vm.createContext(context)
vm.runInContext(source, context)

function equal(actual, expected, label) {
  if (actual !== expected) throw new Error(`${label}: expected ${expected}, got ${actual}`)
}

equal(context.secureState("enabled"), "off", "administrator enabled means Secure Mode off")
equal(context.secureState("disabled"), "on", "administrator disabled means Secure Mode on")
equal(context.secureState("inconsistent"), "error", "inconsistent state remains visible")

equal(context.setupState(false, false, "", "2.2.0"), "checking", "unchecked setup state")
equal(context.setupState(true, false, "", "2.2.0"), "missing", "missing helper needs setup")
equal(context.setupState(true, true, "2.1.0", "2.2.0"), "update", "old helper needs update")
equal(context.setupState(true, true, "", "2.2.0"), "update", "broken helper needs update")
equal(context.setupState(true, true, "2.2.0", "2.2.0"), "ready", "matching helper is ready")

equal(context.stateLabel("enabled"), "Secure Mode OFF", "enabled label")
equal(context.stateLabel("disabled"), "Secure Mode ON", "disabled label")
equal(context.stateLabel("inconsistent"), "Secure Mode ?", "error label")

equal(context.panelTitle("enabled"), "Turn Secure Mode on?", "enable restrictions title")
equal(context.panelTitle("disabled"), "Secure Mode is ON", "restricted title")
equal(context.actionHint("enabled"), "turn Secure Mode on", "enabled action")
equal(context.actionHint("disabled"), "turn Secure Mode off", "disabled action")

console.log("Secure Mode state mapping tests passed")
