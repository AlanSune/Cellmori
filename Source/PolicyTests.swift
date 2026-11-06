// SPDX-License-Identifier: MIT
import Foundation

@main struct PolicyTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAIL: " + name) }
        count += 1
    }
    static func main() throws {
        let now = Date()
        var b = Battery(percent: 81, temperature: 27, cycles: 88, design: 5103, nominal: 4377,
                        voltage: 12, amperage: -500, external: true, charging: false, full: false, failure: 0, lidClosed: false)
        var c = Configuration(); c.mode = .limit
        check(!evaluate(&c, battery: b, now: now).charge, "limit stops above 80")
        b.percent = 77
        check(!evaluate(&c, battery: b, now: now).charge, "hysteresis holds disabled")
        b.percent = 75
        check(evaluate(&c, battery: b, now: now).charge, "resumes at 75")
        b.percent = 79
        check(evaluate(&c, battery: b, now: now).charge, "hysteresis holds enabled")
        b.temperature = 41
        check(!evaluate(&c, battery: b, now: now).charge, "thermal pause")
        b.temperature = 38
        check(!evaluate(&c, battery: b, now: now).charge, "thermal hysteresis")
        b.temperature = 37
        check(evaluate(&c, battery: b, now: now).charge, "thermal recovery")
        b.temperature = 2
        check(!evaluate(&c, battery: b, now: now).charge, "cold pause")
        b.temperature = 6
        check(!evaluate(&c, battery: b, now: now).charge, "cold hysteresis")
        b.temperature = 8
        check(evaluate(&c, battery: b, now: now).charge, "cold recovery")
        c.mode = .discharge; b.percent = 60; b.temperature = 25
        check(evaluate(&c, battery: b, now: now).discharge, "target discharge starts")
        b.lidClosed = true
        check(!evaluate(&c, battery: b, now: now).discharge, "closed lid pauses discharge")
        b.lidClosed = nil
        check(!evaluate(&c, battery: b, now: now).discharge, "unknown lid fails safe")
        b.lidClosed = false; b.percent = 50
        check(!evaluate(&c, battery: b, now: now).discharge && c.mode == .limit, "target complete restores limit")
        c.mode = .discharge; c.dischargeTarget = 20; b.percent = 19
        check(evaluate(&c, battery: b, now: now).charge && c.mode == .limit, "low battery stops discharge")
        c.mode = .discharge; b.percent = 60; b.external = false
        check(!evaluate(&c, battery: b, now: now).discharge, "unplugging restores adapter")
        b.external = true; b.temperature = 45; b.percent = 19
        check(evaluate(&c, battery: b, now: now).charge, "critical battery releases charging gate")
        b.temperature = 25; c.thermalPaused = false; c.mode = .full; b.percent = 100
        check(!evaluate(&c, battery: b, now: now).charge && c.mode == .limit, "temporary full returns to limit")
        c = Configuration(); c.mode = .calibrate; b.percent = 100
        _ = evaluate(&c, battery: b, now: now)
        check(c.stage == "hold", "calibration reaches full")
        c.holdingSeconds = 1790; c.lastTick = now.addingTimeInterval(-3600)
        _ = evaluate(&c, battery: b, now: now)
        check(c.holdingSeconds == 1820 && c.stage == "discharge", "sleep time not counted as full hold")
        b.percent = 80
        check(evaluate(&c, battery: b, now: now).discharge, "calibration discharge")
        b.percent = 20
        check(evaluate(&c, battery: b, now: now).charge && c.stage == "recharge", "calibration floor")
        b.percent = 100
        _ = evaluate(&c, battery: b, now: now)
        check(c.mode == .limit, "calibration completion")
        c.mode = .calibrate; c.stage = "discharge"; c.stageStarted = now.addingTimeInterval(-13*3600); b.percent = 60
        check(!evaluate(&c, battery: b, now: now).discharge && c.mode == .system, "discharge timeout")
        c.mode = .full; c.started = now.addingTimeInterval(-49*3600)
        check(evaluate(&c, battery: b, now: now).charge && c.mode == .system, "operation timeout")
        c = Configuration(); c.mode = .limit; b.failure = 1
        check(evaluate(&c, battery: b, now: now).charge && c.mode == .system, "battery failure releases control")
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(Configuration.self, from: data)
        check(decoded.mode == .system, "configuration round trip")
        c=Configuration();c.mode = .limit;c.target=80
        check(firmwareSettings(for:c)==FirmwareSettings(activation:2,upper:80,lower:75), "firmware limit range")
        c.firmwareOriginal=FirmwareSettings(activation:2,upper:80,lower:79);c.thermalPaused=true
        check(firmwareSettings(for:c)==c.firmwareOriginal, "firmware thermal pause preserves original")
        c.thermalPaused=false;c.mode = .full
        check(firmwareSettings(for:c).activation==0, "firmware full releases limit")
        c.mode = .calibrate
        check(firmwareSettings(for:c).activation==0, "firmware calibration releases limit")
        c.mode = .discharge
        check(firmwareSettings(for:c).activation==0, "firmware manual discharge has no conflicting charge target")
        let backupData=try JSONEncoder().encode(c)
        let backup=try JSONDecoder().decode(Configuration.self,from:backupData)
        check(backup.firmwareOriginal==c.firmwareOriginal, "original firmware setting persists")
        func service(_ binary: Bool = true, _ plist: Bool = true, _ registered: Bool = true, _ running: Bool = true, pid: Int? = 42, state: ServiceState? = nil) -> ServiceInspection {
            ServiceInspection.classify(binary:binary,plist:plist,registered:registered,running:running,pid:pid,state:state,now:now)
        }
        check(service(false,false,false,false,pid:nil).condition == .missing, "service files absent is missing")
        check(service(true,false,false,false,pid:nil).condition == .incomplete, "binary alone is not installed successfully")
        check(service(true,true,false,false,pid:nil).condition == .stopped, "installed files without launchd are stopped")
        check(service(true,true,true,false,pid:nil).condition == .stopped, "registered but exited daemon is stopped")
        check(service().condition == .starting, "running process without heartbeat waits")
        var heartbeat=ServiceState(configuration:Configuration(),message:"ok")
        heartbeat.updated=now;heartbeat.daemonPID=42
        check(service(state:heartbeat).condition == .running, "matching process and fresh heartbeat are healthy")
        heartbeat.updated=now.addingTimeInterval(-66)
        check(service(state:heartbeat).condition == .stale, "old heartbeat cannot imply running successfully")
        heartbeat.updated=now.addingTimeInterval(60)
        check(service(state:heartbeat).condition == .stale, "future clock heartbeat not accepted")
        heartbeat.updated=now;heartbeat.daemonPID=41
        check(service(state:heartbeat).condition == .starting, "old pid response not accepted after restart")
        heartbeat.daemonPID=42;heartbeat.serviceName="other.helper"
        check(service(state:heartbeat).condition == .failed, "wrong service identity rejected")
        heartbeat.serviceName=serviceIdentifier;heartbeat.helperVersion="0.2.0"
        check(service(state:heartbeat).condition == .updateAvailable, "old helper version clearly distinguished")
        let denied=ServiceInspection.classify(binary:true,plist:true,registered:false,running:false,pid:nil,state:nil,now:now,permissionDenied:true)
        check(denied.condition == .failed, "permission failure does not claim daemon stopped")
        b.charging=true;b.external=true;b.amperage=1000
        check(PowerDisplayState.resolve(b) == .charging, "charging indicator")
        b.charging=false;b.amperage=0
        check(PowerDisplayState.resolve(b) == .external, "external power without charging indicator")
        b.external=false;b.amperage = -500
        check(PowerDisplayState.resolve(b) == .battery, "battery power indicator")
        b.external=true
        check(PowerDisplayState.resolve(b) == .external, "negative current does not override external fallback")
        check(PowerDisplayState.resolve(nil) == .unavailable, "missing telemetry has no false power state")
        c=Configuration();c.mode = .adapterLimit;c.adapterFallback=true
        b.external=true;b.lidClosed=false;b.failure=0;b.temperature=25;b.percent=81
        check(evaluate(&c,battery:b,now:now).discharge, "adapter fallback cuts wall power at upper target")
        b.percent=77
        check(evaluate(&c,battery:b,now:now).discharge, "adapter fallback keeps hysteresis state")
        b.percent=75
        check(!evaluate(&c,battery:b,now:now).discharge && c.chargeAllowed, "adapter fallback restores wall power at lower target")
        b.percent=81;b.lidClosed=true
        check(!evaluate(&c,battery:b,now:now).discharge, "adapter fallback restores supply when lid closes")
        b.lidClosed=nil
        check(!evaluate(&c,battery:b,now:now).discharge, "adapter fallback unknown lid fails safe")
        b.lidClosed=false;b.external=false
        check(!evaluate(&c,battery:b,now:now).discharge, "adapter fallback physical unplug releases adapter")
        b.external=true;b.temperature=42
        check(!evaluate(&c,battery:b,now:now).discharge, "adapter fallback thermal pause restores power")
        b.temperature=25;b.percent=19
        check(!evaluate(&c,battery:b,now:now).discharge && c.chargeAllowed, "adapter fallback low battery restores supply")
        let old=Data(#"{"mode":"system","target":80,"dischargeTarget":50,"temperatureLimit":40,"started":0,"stage":"charge","stageStarted":0,"holdingSeconds":0,"chargeAllowed":true,"thermalPaused":false,"ownsHardware":false}"#.utf8)
        let migrated=try JSONDecoder().decode(Configuration.self,from:old)
        check(migrated.adapterFallback == nil, "existing configuration never opts into adapter fallback")
        b.charging=false;b.external=false;b.amperage=1500
        check(PowerDisplayState.resolve(b) == .battery, "positive current alone does not determine supply source")
        b.charging=true;b.amperage = -500
        check(PowerDisplayState.resolve(b) == .charging, "negative current does not override charging status")
        b.charging=false;b.amperage=0;b.providingPowerSource="AC Power"
        check(PowerDisplayState.resolve(b) == .external, "native AC source overrides raw disconnected flag")
        b.external=true;b.providingPowerSource="Battery Power"
        check(PowerDisplayState.resolve(b) == .battery, "native battery source overrides physical adapter presence")
        b.providingPowerSource="AC Power";b.external=true;b.charging=false;b.amperage = -316
        check(PowerDisplayState.resolve(b) == .external, "regression: macOS AC source with negative battery current")
        b.amperage=1500
        check(PowerDisplayState.resolve(b) == .external, "AC source alone does not imply charging")
        b.charging=true
        check(PowerDisplayState.resolve(b) == .charging, "AC source with charging status")
        b.providingPowerSource="Battery Power"
        check(PowerDisplayState.resolve(b) == .battery, "native battery source wins conflicting charging flag")
        c=Configuration();c.mode = .limit;c.target=79
        check(firmwareSleepSettings(for:c)==FirmwareSettings(activation:2,upper:79,lower:74), "sleep keeps daily firmware ceiling")
        c.mode = .discharge;c.dischargeTarget=79
        check(firmwareSleepSettings(for:c).upper==79 && firmwareSleepSettings(for:c).activation==2, "manual discharge does not remove ceiling before sleep")
        c.dischargeTarget=20
        check(firmwareSleepSettings(for:c).upper==40, "sleep discharge ceiling keeps conservative minimum")
        c.mode = .full
        check(firmwareSleepSettings(for:c).upper==100, "explicit full-charge intent retained for sleep")
        c.mode = .calibrate;c.stage="discharge"
        check(firmwareSleepSettings(for:c).upper==79, "calibration discharge sleep retains daily ceiling")
        c=Configuration();c.mode = .limit;c.target=79
        check(limitSettingsApplied(c,target:79,temperature:40), "unchanged applied daily limit")
        check(!limitSettingsApplied(c,target:80,temperature:40), "edited limit is pending")
        check(!limitSettingsApplied(c,target:79,temperature:39), "edited thermal setting is pending")
        c.mode = .system
        check(!limitSettingsApplied(c,target:79,temperature:40), "system mode is not an applied policy")
        c.mode = .full
        check(!limitSettingsApplied(c,target:79,temperature:40), "temporary flow does not claim daily limit active")
        b.external=true;b.charging=false;b.providingPowerSource="AC Power";b.lidClosed=false
        check(temporaryFlowStatus(c,battery:b)?.contains("等待系统开始充电") == true, "full command does not claim observed charging")
        b.charging=true
        check(temporaryFlowStatus(c,battery:b)?.contains("正在充电") == true, "observed full charging")
        c.thermalPaused=true
        check(temporaryFlowStatus(c,battery:b)?.contains("温度保护") == true, "thermal pause overrides charging text")
        c.thermalPaused=false;b.external=false;b.providingPowerSource="Battery Power"
        check(temporaryFlowStatus(c,battery:b)?.contains("等待接通电源") == true, "full waits for actual adapter")
        c.mode = .discharge;b.external=true;b.lidClosed=true
        check(temporaryFlowStatus(c,battery:b)?.contains("已暂停") == true, "discharge closed lid status")
        b.lidClosed=false
        check(temporaryFlowStatus(c,battery:b)?.contains("进行中") == true, "discharge native battery status")
        b.external=true;b.providingPowerSource="AC Power"
        check(temporaryFlowStatus(c,battery:b)?.contains("等待系统切换") == true, "discharge submission does not claim switching complete")
        check(temporaryFlowStatus(c,battery:nil) == "正在读取电池状态", "missing telemetry avoids false active status")
        c.mode = .calibrate;c.stage="recharge";b.charging=false
        check(temporaryFlowStatus(c,battery:b)?.contains("等待系统开始充电") == true, "calibration recharge waits for actual charging")
        c.mode = .limit
        check(temporaryFlowStatus(c,battery:b) == nil, "daily policy uses backend status")
        check(permittedControlRequest(["ping"]), "read-only control handshake")
        check(permittedControlRequest(["reset"]), "finite reset request")
        check(permittedControlRequest(["configure","discharge","79","40","50"]), "typed discharge request")
        check(!permittedControlRequest(["prepare-update"]), "IPC cannot invoke installer maintenance")
        check(!permittedControlRequest(["tick"]), "IPC cannot inject background ticks")
        check(!permittedControlRequest(["serve"]), "IPC cannot launch servers")
        check(!permittedControlRequest(["/bin/sh","-c","id"]), "IPC cannot execute shell commands")
        check(!permittedControlRequest(["configure","limit","101","40","50"]), "IPC rejects invalid upper limit")
        check(!permittedControlRequest(["configure","limit","79","nan","50"]), "IPC rejects nonfinite temperature")
        check(!permittedControlRequest(["configure","limit","79","40","19"]), "IPC enforces discharge floor")
        check(!permittedControlRequest(["configure","limit","79","40","50","extra"]), "IPC rejects extra arguments")
        check(!permittedControlRequest(["reset","/tmp/file"]), "IPC accepts no caller-supplied paths")
        check(ControlIdentity.validHash(String(repeating:"a",count:40)), "exact signing hash syntax")
        check(!ControlIdentity.validHash("a\" or true"), "requirement injection rejected")
        check(!ControlIdentity.validHash(String(repeating:"a",count:39)), "truncated signing hash rejected")
        print("PASS: \(count) policy, service and power-display checks; no hardware writes")
    }
}
