const fs = require("fs")
const path = require("path")
const vm = require("vm")

const root = path.resolve(__dirname, "..")
const target = "abacon"

function loadRule(file) {
  const registered = []
  const context = {
    polkit: {
      Result: { AUTH_SELF: "AUTH_SELF", NO: "NO" },
      addRule: rule => registered.push(rule)
    }
  }
  vm.createContext(context)
  const source = fs.readFileSync(path.join(root, "polkit", file), "utf8")
    .replaceAll("@@TARGET_USER@@", target)
  vm.runInContext(source, context, { filename: file })
  if (registered.length !== 1) throw new Error(`${file}: expected exactly one rule`)
  return registered[0]
}

const recovery = loadRule("05-omarchy-admin-toggle-recovery.rules.in")
const off = loadRule("10-omarchy-admin-toggle-off.rules.in")
const manage = loadRule("20-omarchy-admin-toggle-manage.rules.in")

const enable = { id: "com.github.andrewbacon.omarchy-admin-toggle.enable" }
const disable = { id: "com.github.andrewbacon.omarchy-admin-toggle.disable" }
const generic = { id: "org.freedesktop.policykit.exec" }
const localTarget = { user: target, local: true, active: true }
const inactiveTarget = { user: target, local: true, active: false }
const remoteTarget = { user: target, local: false, active: true }
const other = { user: "someoneelse", local: true, active: true }

function decide(rules, action, subject) {
  for (const rule of rules) {
    const result = rule(action, subject)
    if (result !== null && result !== undefined) return result
  }
  return null
}

function equal(actual, expected, label) {
  if (actual !== expected) throw new Error(`${label}: expected ${expected}, got ${actual}`)
}

equal(decide([recovery, manage], enable, localTarget), "AUTH_SELF", "ON enable recovery")
equal(decide([recovery, manage], disable, localTarget), "AUTH_SELF", "ON disable")
equal(decide([recovery, manage], generic, localTarget), null, "ON generic falls through")

equal(decide([recovery, off, manage], enable, localTarget), "AUTH_SELF", "OFF recovery")
equal(decide([recovery, off, manage], disable, localTarget), "NO", "OFF disable denied")
equal(decide([recovery, off, manage], generic, localTarget), "NO", "OFF generic denied")
equal(decide([recovery, off, manage], enable, inactiveTarget), "NO", "inactive recovery denied")
equal(decide([recovery, off, manage], enable, remoteTarget), "NO", "remote recovery denied")
equal(decide([recovery, off, manage], enable, other), "NO", "other-user recovery denied")
equal(decide([recovery, off, manage], generic, other), null, "other-user generic untouched")

console.log("Polkit rule-order tests passed")

