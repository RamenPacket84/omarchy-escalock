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

const on = loadRule("00-00-omarchy-escalock-on.rules.in")
const off = loadRule("00-00-omarchy-escalock-off.rules.in")

const enable = { id: "com.github.andrewbacon.omarchy-escalock.enable" }
const disable = { id: "com.github.andrewbacon.omarchy-escalock.disable" }
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

equal(decide([on], enable, localTarget), "AUTH_SELF", "ON enable recovery")
equal(decide([on], disable, localTarget), "AUTH_SELF", "ON disable")
equal(decide([on], generic, localTarget), null, "ON generic falls through")

equal(decide([off], enable, localTarget), "AUTH_SELF", "OFF recovery")
equal(decide([off], disable, localTarget), "NO", "OFF disable denied")
equal(decide([off], generic, localTarget), "NO", "OFF generic denied")
equal(decide([off], enable, inactiveTarget), "NO", "inactive recovery denied")
equal(decide([off], enable, remoteTarget), "NO", "remote recovery denied")
equal(decide([off], enable, other), null, "other-user recovery untouched")
equal(decide([off], generic, other), null, "other-user generic untouched")

const earlierAllow = function() { return "YES" }
equal(decide([earlierAllow, off], generic, localTarget), "YES",
  "an earlier rule would preempt EscaLock and must be rejected by setup")

console.log("Polkit rule-order tests passed")
