"""Loads the SimBLE loader into simulator apps debugged from Xcode while SimBLE is running.

Xcode sets DYLD_INSERT_LIBRARIES itself, which hides the simulator-wide value the Mac app sets, so
debugged apps need this hook. SimBLE installs this file next to the loader and imports it from
~/.lldbinit. A dummy-target breakpoint on UIApplicationMain is copied into every new target; it
auto-continues, and the loader then asks the Mac app whether this app is selected.
"""

import os
import socket

import lldb

LOADER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "libSimBLELoader.dylib")
BREAKPOINT_NAME = "sim-ble-bridge"


def bridge_is_running():
    port = int(os.environ.get("SIM_BLE_BRIDGE_PORT", "50505"))
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.settimeout(0.2)
        return probe.connect_ex(("127.0.0.1", port)) == 0


def on_application_main(frame, bp_loc, internal_dict):
    process = frame.GetThread().GetProcess()
    if "simulator" not in (process.GetTarget().GetTriple() or ""):
        return False
    if not os.path.exists(LOADER) or not bridge_is_running():
        return False
    error = lldb.SBError()
    process.LoadImage(lldb.SBFileSpec(LOADER), error)
    if error.Fail():
        print(f"[SimBLE] failed to load the loader: {error}")
    return False


def __lldb_init_module(debugger, internal_dict):
    dummy = debugger.GetDummyTarget()
    names = lldb.SBStringList()
    dummy.GetBreakpointNames(names)
    if any(names.GetStringAtIndex(index) == BREAKPOINT_NAME for index in range(names.GetSize())):
        return
    breakpoint = dummy.BreakpointCreateByName("UIApplicationMain")
    breakpoint.AddName(BREAKPOINT_NAME)
    breakpoint.SetAutoContinue(True)
    breakpoint.SetScriptCallbackFunction(f"{__name__}.on_application_main")
