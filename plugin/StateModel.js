.pragma library

// The helper reports whether administrator privileges are enabled. Secure Mode
// is intentionally the inverse concept presented to the desktop user.
function secureState(adminState) {
  if (adminState === "disabled") return "on"
  if (adminState === "enabled") return "off"
  return "error"
}

function setupState(versionChecked, helperPresent, installedVersion, expectedVersion) {
  if (!versionChecked) return "checking"
  if (!helperPresent) return "missing"
  if (installedVersion !== expectedVersion) return "update"
  return "ready"
}

function stateLabel(adminState) {
  var state = secureState(adminState)
  if (state === "on") return "Secure Mode ON"
  if (state === "off") return "Secure Mode OFF"
  return "Secure Mode ?"
}

function statusMessage(adminState) {
  var state = secureState(adminState)
  if (state === "on") return "Secure Mode is ON. General administrator elevation is blocked."
  if (state === "off") return "Secure Mode is OFF. Administrator privileges are available."
  return "Secure Mode state is inconsistent."
}

function panelTitle(adminState) {
  var state = secureState(adminState)
  if (state === "on") return "Secure Mode is ON"
  if (state === "off") return "Turn Secure Mode on?"
  return "Secure Mode state error"
}

function actionHint(adminState) {
  var state = secureState(adminState)
  if (state === "on") return "turn Secure Mode off"
  if (state === "off") return "turn Secure Mode on"
  return "inspect state"
}
