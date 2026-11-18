// SPDX-License-Identifier: MIT
import Foundation

private final class SimulatedSystem {
    var flag = false
    var snapshot: SleepHoldSnapshot?
    var writes: [Bool] = []
    var failSave = false, failRead = false, failWrite = false, failRemove = false, ignoreWrite = false
    var beforeWrite: ((Bool) -> Void)?
    var controller: SleepHoldController {
        SleepHoldController(load: { self.snapshot }, save: { value in
            if self.failSave { throw CMError.message("disk failure") }
            self.snapshot = value
        }, remove: {
            if self.failRemove { throw CMError.message("remove failure") }
            self.snapshot = nil
        }, read: {
            if self.failRead { throw CMError.message("read failure") }
            return self.flag
        }, write: { value in
            precondition(self.snapshot != nil, "snapshot must exist before global write")
            self.beforeWrite?(value)
            if self.failWrite { throw CMError.message("write failure") }
            self.writes.append(value)
            if !self.ignoreWrite { self.flag = value }
        })
    }
}
@main struct SleepControlTests {
    static var count = 0
    static func check(_ condition: Bool, _ name: String) {
        guard condition else { fatalError("FAIL: " + name) };count += 1
    }
    static func rejects(_ name: String, _ body: () throws -> Void) {
        do { try body();fatalError("FAIL: " + name) } catch { count += 1 }
    }
    static func main() throws {
        var timerFired = false
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in timerFired = true }
        let response = try SystemSleepControl.output(executable: "/bin/sh", arguments: ["-c", "sleep 0.08; printf done"])
        check(response == "done", "bounded child returns output")
        check(!timerFired, "waiting never reenters the policy timer run loop")
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        check(timerFired, "pending policy timer runs only after operation returns")
        timer.invalidate()
        rejects("nonzero child exit is reported") { _ = try SystemSleepControl.output(executable: "/bin/sh", arguments: ["-c", "echo failed >&2; exit 2"]) }
        let began = ProcessInfo.processInfo.systemUptime
        rejects("stalled child is bounded") { _ = try SystemSleepControl.output(executable: "/bin/sleep", arguments: ["5"], timeout: 0.05) }
        check(ProcessInfo.processInfo.systemUptime-began < 1, "timeout returns without waiting for stalled child")
        rejects("oversized child output is bounded") { _ = try SystemSleepControl.output(executable: "/usr/bin/yes", arguments: ["x"]) }
        rejects("missing executable is reported") { _ = try SystemSleepControl.output(executable: "/nonexistent/cellmori-test", arguments: []) }
        check(try SystemSleepControl.parseDisabled("System-wide power settings:\n SleepDisabled\t0\n") == false,"parse original normal sleep")
        check(try SystemSleepControl.parseDisabled(" SleepDisabled 1\n") == true,"parse pre-existing disable")
        rejects("missing flag is not silently assumed false") { _ = try SystemSleepControl.parseDisabled("sleep 1") }
        rejects("ambiguous flags rejected") { _ = try SystemSleepControl.parseDisabled("SleepDisabled 0\nSleepDisabled 1") }
        rejects("unknown state rejected") { _ = try SystemSleepControl.parseDisabled("SleepDisabled 2") }
        var env = SimulatedSystem()
        check(try env.controller.acquire(),"acquire confirmed")
        check(env.flag && env.snapshot?.originallyDisabled == false && env.writes == [true],"persist original before write")
        _ = try env.controller.acquire()
        check(env.snapshot?.originallyDisabled == false && env.writes == [true],"repeated acquisition preserves original and avoids repeated writes")
        try env.controller.release()
        check(!env.flag && env.snapshot == nil && env.writes == [true,false],"completion restores original sleep")
        try env.controller.release();check(env.writes == [true,false],"release is idempotent")
        env = SimulatedSystem();env.flag = true
        _ = try env.controller.acquire();try env.controller.release()
        check(env.flag && env.writes.isEmpty && env.snapshot == nil,"never cancel a pre-existing disable-sleep setting")
        env = SimulatedSystem();env.failSave = true
        rejects("cannot acquire without durable recovery data") { _ = try env.controller.acquire() }
        check(!env.flag && env.writes.isEmpty,"save failure causes no global writes")
        env = SimulatedSystem();env.failRead = true
        rejects("cannot acquire when original state cannot be read") { _ = try env.controller.acquire() }
        check(env.snapshot == nil && env.writes.isEmpty,"read failure never changes system")
        env = SimulatedSystem();env.ignoreWrite = true
        rejects("ignored enable write is not called success") { _ = try env.controller.acquire() }
        check(env.snapshot != nil && !env.flag,"unconfirmed enable keeps recovery record")
        env.ignoreWrite = false;try env.controller.release()
        check(env.snapshot == nil && !env.flag,"failed acquisition can be safely recovered")
        env = SimulatedSystem();_ = try env.controller.acquire()
        let afterCrash = env.controller // Recreated owner only has durable snapshot + global flag.
        try afterCrash.release()
        check(!env.flag && env.snapshot == nil,"startup recovers a flag left by process crash")
        env = SimulatedSystem();_ = try env.controller.acquire();env.failWrite = true
        rejects("restore failure surfaced") { try env.controller.release() }
        check(env.flag && env.snapshot != nil,"restore failure retains retry information")
        env.failWrite = false;try env.controller.release()
        check(!env.flag && env.snapshot == nil,"next retry restores sleep")
        env = SimulatedSystem();_ = try env.controller.acquire();env.ignoreWrite = true
        rejects("ignored disable write surfaced") { try env.controller.release() }
        check(env.snapshot != nil && env.flag,"failed readback retains snapshot")
        env.ignoreWrite = false;try env.controller.release()
        env = SimulatedSystem();_ = try env.controller.acquire();env.failRemove = true
        rejects("failed marker deletion surfaced") { try env.controller.release() }
        check(!env.flag && env.snapshot != nil,"marker may remain after restored system")
        env.failRemove = false;try env.controller.release()
        check(env.writes == [true,false] && env.snapshot == nil,"marker cleanup retry does not re-disable sleep")
        env = SimulatedSystem();env.flag = true;_ = try env.controller.acquire();env.flag = false
        try env.controller.release()
        check(!env.flag && env.writes.isEmpty,"respect later external re-enable of sleep")

        let now = Date()
        var c = Configuration();c.mode = .discharge;c.dischargeTarget = 90;c.dischargeKeepAwake = true
        var b = Battery(percent:95,temperature:25,cycles:1,design:5000,nominal:4900,voltage:12,amperage:-500,
                        external:true,charging:false,full:false,failure:0,lidClosed:true)
        check(needsDischargeSleepHold(c,battery:b,now:now),"opted-in closed-lid task requests hold")
        check(!evaluate(&c,battery:b,now:now).discharge,"saved preference alone never authorizes closed-lid discharge")
        check(evaluate(&c,battery:b,now:now,sleepHoldConfirmed:true).discharge,"confirmed hold permits closed-lid discharge")
        c.dischargeKeepAwake = false
        check(!needsDischargeSleepHold(c,battery:b,now:now),"default off never takes over sleep")
        check(!evaluate(&c,battery:b,now:now,sleepHoldConfirmed:true).discharge,"hold does not override absent opt-in")
        c.dischargeKeepAwake = true;b.external = false
        check(!needsDischargeSleepHold(c,battery:b,now:now),"unplugging releases hold")
        b.external = true;b.temperature = 42
        check(!needsDischargeSleepHold(c,battery:b,now:now),"temperature pause releases hold")
        b.temperature = 25;b.percent = 90
        check(!needsDischargeSleepHold(c,battery:b,now:now),"target reached releases hold")
        b.percent = 95;c.started = now.addingTimeInterval(-49*3600)
        check(!needsDischargeSleepHold(c,battery:b,now:now),"task timeout releases hold")
        c.started = now;c.mode = .limit
        check(!needsDischargeSleepHold(c,battery:b,now:now),"stop action releases hold")
        c.mode = .system
        check(!needsDischargeSleepHold(c,battery:b,now:now),"reset releases hold")
        c.mode = .retiredAdapterLimit
        check(!needsDischargeSleepHold(c,battery:b,now:now),"retired configuration never holds sleep")
        c.mode = .calibrate;c.stage = "charge"
        check(!needsDischargeSleepHold(c,battery:b,now:now),"calibration charge follows normal sleep behavior")
        c.stage = "discharge";c.stageStarted = now
        check(needsDischargeSleepHold(c,battery:b,now:now),"calibration active discharge can hold sleep")
        c.stageStarted = now.addingTimeInterval(-13*3600)
        check(!needsDischargeSleepHold(c,battery:b,now:now),"calibration discharge timeout releases hold")
        c.stage = "hold";c.stageStarted = now;c.lastTick = now.addingTimeInterval(-20);c.holdingSeconds = 1790;b.percent = 100
        _ = needsDischargeSleepHold(c,battery:b,now:now)
        check(c.stage == "hold" && c.holdingSeconds == 1790 && c.lastTick == now.addingTimeInterval(-20),"planning never advances persistent calibration state")

        // Exercise the keep-awake -> adapter isolation -> ceiling release -> stop
        // handoff with actual controller/policy functions and simulated hardware.
        env = SimulatedSystem();c = Configuration();c.mode = .discharge;c.dischargeTarget = 90;c.dischargeKeepAwake = true
        b.percent = 95;b.lidClosed = true
        var firmware = firmwareSettings(for:c);var cut = false
        env.beforeWrite = { disabled in
            if !disabled { check(!cut && firmware.activation == 2 && firmware.upper == 80,"restore sleep only after ceiling and adapter recovery") }
        }
        let confirmed = try env.controller.acquire()
        let active = evaluate(&c,battery:b,now:now,sleepHoldConfirmed:confirmed)
        _ = try applyFirmwareProtection(firmwareSettings(for:c,discharging:active.discharge),discharge:active.discharge,
            write:{ firmware=$0 },adapter:{ value in
                if value { check(env.flag,"hold acquired before adapter isolation") }
                cut=value
            },read:{ firmware })
        check(cut && firmware.activation == 0,"closed-lid active discharge uses confirmed keep-awake")
        b.percent = 90
        let done = evaluate(&c,battery:b,now:now,sleepHoldConfirmed:confirmed)
        _ = try applyFirmwareProtection(firmwareSettings(for:c,discharging:done.discharge),discharge:done.discharge,
            write:{ firmware=$0 },adapter:{ cut=$0 },read:{ firmware })
        try env.controller.release()
        check(c.mode == .limit && !env.flag && env.snapshot == nil,"automatic completion restores daily limit and original sleep")
        print("PASS: \(count) sleep control and recovery checks; simulated system only, no pmset writes or hardware access")
    }
}
