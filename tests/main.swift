import Foundation

var failures = 0

func check<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual != expected {
        failures += 1
        print("FAIL \(label): got \(actual), expected \(expected)")
    }
}

let url = "x-coredata://STORE-1/CopyJob/p196"
func stamp(_ second: Int) -> String { String(format: "2026-11-02 09:32:%02d.000+0000", second) }
func state(_ second: Int, _ from: String, _ to: String, _ job: String = url) -> String {
    "I \(stamp(second)) <JBSTE> [1] state transition: \(job) com.pomfort.workState.\(from) -> com.pomfort.workState.\(to)"
}
func started(_ tracker: Tracker, id: String = "Z2z.dij", job: String = url) {
    tracker.ingest("I \(stamp(0)) <WorkflowScheduling> [1] scheduling for workflow `MAVIC Workflow` with: WorkflowConfig(x)")
    tracker.ingest("I \(stamp(0)) <WorkflowScheduling> [1] scheduled job(s) for workflow: [\"\(id)\"]")
    tracker.ingest("I \(stamp(1)) <JBX:\(id)> [1] tasks will be executed in the following buckets:")
    tracker.ingest("a.MP4 | b.LRF")
    tracker.ingest(state(1, "scheduled", "started", job))
}
func info(done: Double = 0, doneTasks: Int = 0) -> JobInfo {
    var info = JobInfo(title: "REEL")
    info.add(name: "a.MP4", size: 90, isDone: false)
    info.add(name: "b.LRF", size: 10, isDone: false)
    info.alreadyDoneBytes = done
    info.alreadyDoneTasks = doneTasks
    return info
}

// A job's identity, kind and database row come from the state transition.
var tracker = Tracker()
started(tracker)
check(tracker.jobs.count, 1, "job started")
check(tracker.jobs[0].id, "Z2z.dij", "job id from the bucket line")
check(tracker.jobs[0].kindLabel, "Offload", "copy job label")
check(tracker.jobs[0].title, "MAVIC Workflow", "title before database lookup")
check(tracker.jobs[0].databaseKey?.row, 196, "database row")
check(tracker.jobs[0].databaseKey?.store, "STORE-1", "database store")
check(tracker.jobs[0].fraction, nil, "no percentage without a real total")

// Progress is weighted by size and speed text is cleaned up.
tracker.setInfo(info(), forJob: "Z2z.dij")
tracker.ingest("I \(stamp(2)) <JBX:Z2z.dij> [1] MSG: CopyTaskExecution <a.MP4> [info ] copy [prog ] 7%")
tracker.ingest("I \(stamp(3)) <JBX:Z2z.dij> [1] MSG: CopyTaskExecution <a.MP4> [prog ] 50% [spd  ] 466.6 MB (466,604,119.02 bytes)/s")
check(tracker.jobs[0].fraction, 0.45, "half of the 90 byte file")
check(tracker.jobs[0].phase, "copy", "phase")
check(tracker.jobs[0].speed, "466.6 MB/s", "speed")
check(tracker.jobs[0].currentFile, "a.MP4", "current file")
tracker.ingest("I \(stamp(4)) <Z2z.dij.bN9> [1] FIN: CopyTaskExecution <a.MP4> fileToolResult([copiedSize: 90])")
check(tracker.jobs[0].fraction, 0.9, "finished file counts in full")
check(tracker.jobs[0].doneTasks, 1, "finished task count")
check(tracker.jobs[0].active.isEmpty, true, "finished file no longer in flight")

// Only an explicit success counts as complete.
tracker.ingest("I \(stamp(5)) <Z2z.dij.xyz> [1] FIN: CopyTaskExecution <b.LRF> fileToolResult([copiedSize: 10])")
tracker.ingest(state(5, "started", "execCompl"))
check(tracker.jobs[0].state, .finishing, "all tasks done is not success yet")
tracker.ingest(state(6, "execCompl", "finishedSuccessfully"))
check(tracker.jobs[0].state, .succeeded, "success")
check(tracker.jobs[0].fraction, 1, "success is 100%")

// Failures keep their error text, and only a failed job survives ordinary pruning.
tracker = Tracker()
started(tracker)
tracker.ingest(#"E \#(stamp(2)) <JBX:Z2z.dij> [1] ERR: CopyTaskExecution <a.MP4> Error Domain=com.pomfort.silverstack.error.copy Code=108 "The source file "a.MP4" can not be opened." UserInfo={NSFilePath=/x}"#)
tracker.ingest(state(3, "started", "finishedUnsuccessfully"))
check(tracker.jobs[0].state, .failed, "failure")
check(tracker.jobs[0].errors, 1, "error count")
check(tracker.jobs[0].lastError, #"The source file "a.MP4" can not be opened."#, "error text keeps inner quotes")
tracker.prune(now: Date(), finishedFor: 8)
check(tracker.jobs.count, 1, "failed job stays until dismissed")
tracker.dismiss("Z2z.dij")
check(tracker.jobs.isEmpty, true, "dismissed")

tracker = Tracker()
started(tracker)
tracker.ingest(state(2, "started", "aborted"))
check(tracker.jobs[0].state, .cancelled, "cancelled")
tracker.prune(now: Date(), finishedFor: 8)
check(tracker.jobs.isEmpty, true, "cancelled job clears itself")

// A retried job restarts on the same row, and work from the earlier attempt stays counted.
tracker = Tracker()
started(tracker)
tracker.ingest(state(2, "started", "finishedUnsuccessfully"))
tracker.ingest(state(3, "finishedUnsuccessfully", "scheduled"))
started(tracker, id: "abc.def")
check(tracker.jobs.count, 1, "retry replaces the failed entry")
tracker.setInfo(info(done: 90, doneTasks: 1), forJob: "abc.def")
check(tracker.jobs[0].fraction, 0.9, "retry starts from earlier work")
tracker.ingest("I \(stamp(4)) <abc.def.xyz> [1] FIN: CopyTaskExecution <b.LRF> fileToolResult([copiedSize: 10])")
check(tracker.jobs[0].fraction, 1, "retry completes")

// Files finished before the sizes loaded must not be counted twice.
tracker = Tracker()
started(tracker)
tracker.ingest("I \(stamp(2)) <Z2z.dij.xyz> [1] FIN: CopyTaskExecution <a.MP4> fileToolResult([copiedSize: 90])")
tracker.setInfo(info(done: 90, doneTasks: 1), forJob: "Z2z.dij")
check(tracker.jobs[0].fraction, 0.9, "late lookup does not double count")

// Transcodes have no byte sizes, so they fall back to counting tasks.
tracker = Tracker()
started(tracker, job: "x-coredata://STORE-1/RenderJob/p195")
check(tracker.jobs[0].kindLabel, "Transcode", "render label")
tracker.setInfo(JobInfo(title: "R", totalTasks: 4), forJob: "Z2z.dij")
tracker.ingest("I \(stamp(2)) <JBX:Z2z.dij> [1] MSG: RenderTaskExecution <a.MP4> [prog ] 50% [spd  ] 216 FPS")
check(tracker.jobs[0].fraction, 0.125, "half of one of four tasks")
check(tracker.jobs[0].speed, "216 FPS", "render speed")

// Clips logged without their extension still count by size, as seen on Venice verifies.
tracker = Tracker()
started(tracker, job: "x-coredata://STORE-1/VerifyJob/p143")
var clips = JobInfo(title: "R")
clips.add(name: "D012C086_261030DU.MXF", size: 90, isDone: false)
clips.add(name: "D012C086_261030DUM01.XML", size: 10, isDone: false)
tracker.setInfo(clips, forJob: "Z2z.dij")
tracker.ingest("I \(stamp(2)) <Z2z.dij.xyz> [1] FIN: VerifyTaskExecution <D012C086_261030DU> regularFile(x)")
check(tracker.jobs[0].fraction, 0.9, "clip matched without extension")

// Files sharing a name across card folders add up to the right total.
tracker = Tracker()
started(tracker)
var repeated = JobInfo(title: "R")
repeated.add(name: "A.MP4", size: 30, isDone: false)
repeated.add(name: "A.MP4", size: 70, isDone: false)
tracker.setInfo(repeated, forJob: "Z2z.dij")
tracker.ingest("I \(stamp(2)) <Z2z.dij.xyz> [1] FIN: CopyTaskExecution <A.MP4> fileToolResult(x)")
tracker.ingest("I \(stamp(3)) <Z2z.dij.abc> [1] FIN: CopyTaskExecution <A.MP4> fileToolResult(x)")
check(tracker.jobs[0].fraction, 1, "repeated names reach 100%")

// A progress line logged after its file's FIN must not count the file twice.
tracker = Tracker()
started(tracker)
tracker.setInfo(info(), forJob: "Z2z.dij")
tracker.ingest("I \(stamp(2)) <Z2z.dij.xyz> [1] FIN: CopyTaskExecution <a.MP4> fileToolResult(x)")
tracker.ingest("I \(stamp(2)) <JBX:Z2z.dij> [1] MSG: CopyTaskExecution <a.MP4> [prog ] 99% [spd  ] 1 MB (1 bytes)/s")
check(tracker.jobs[0].fraction, 0.9, "late progress line ignored")

// Finished jobs go to the recent list, newest first, and a retry takes the job back out.
tracker = Tracker()
started(tracker)
tracker.ingest(state(2, "started", "finishedUnsuccessfully"))
check(tracker.recent.map(\.state), [.failed], "failure is recorded")
tracker.ingest(state(3, "finishedUnsuccessfully", "scheduled"))
started(tracker, id: "abc.def")
check(tracker.recent.isEmpty, true, "retry leaves the recent list")
tracker.setInfo(info(), forJob: "abc.def")
tracker.ingest(state(4, "started", "execCompl"))
tracker.ingest(state(5, "execCompl", "finishedSuccessfully"))
let other = "x-coredata://STORE-1/RenderJob/p200"
started(tracker, id: "new.job", job: other)
tracker.ingest(state(6, "started", "aborted", other))
check(tracker.recent.map(\.state), [.cancelled, .succeeded], "newest first")
check(tracker.recent[1].info?.totalBytes, 100, "keeps the job size")
check(tracker.recent[1].title, "REEL", "keeps the reel name")
tracker.prune(now: Date(), finishedFor: 0)
tracker.clear()
check(tracker.jobs.isEmpty, true, "live list cleared")
check(tracker.recent.count, 2, "recent list outlives the live list")

tracker = Tracker()
for row in 1...20 {
    let job = "x-coredata://STORE-1/CopyJob/p\(row)"
    started(tracker, id: "job.\(row)", job: job)
    tracker.ingest(state(2, "started", "finishedSuccessfully", job))
}
check(tracker.recent.count, 16, "recent list is capped")
check(tracker.recent[0].id, "job.20", "cap keeps the newest")

check(Format.ago(30), "just now", "seconds ago")
check(Format.ago(720), "12m ago", "minutes ago")
check(Format.ago(7200), "2h ago", "hours ago")
check(Format.ago(172800), "2d ago", "days ago")

// Volume ticks. A green tick has to mean every file on this card, exactly as it is now, was
// copied by a successful job, because it reads as safe to format.
func files(_ list: [(String, Double)]) -> AnySequence<(path: String, size: Double)> {
    AnySequence(list.map { (path: $0.0, size: $0.1) })
}
var record = IngestRecord(copied: ["/CLIP/C0012.MP4": 100, "/CLIP/C0012M01.XML": 5, "/THMBNL/C0012T1-1##.JPG": 7])
let card: [(String, Double)] = [("/CLIP/C0012.MP4", 100), ("/CLIP/C0012M01.XML", 5), ("/THMBNL/C0012T01.JPG", 7)]
check(VolumeCheck.isIngested(record, files: files(card)), true, "every file copied")
check(VolumeCheck.isIngested(record, files: files(card + [("/CLIP/C0013.MP4", 50)])), false, "new clip on the card")
check(VolumeCheck.isIngested(record, files: files([("/CLIP/C0012.MP4", 99)] + card.dropFirst())), false, "same name, different size")
check(VolumeCheck.isIngested(record, files: files([("/THMBNL/C0012T01.JPG", 8)] + card.dropLast())), false, "sequence size differs")
check(VolumeCheck.isIngested(record, files: files([])), false, "an empty card has nothing to tick")
check(VolumeCheck.isIngested(IngestRecord(copied: ["/A/C.MP4": 1]), files: files([("/B/C.MP4", 1)])), false, "same file in another folder")
let run = IngestRecord(copied: ["/S/F2-3##.DNG": 30])
check(VolumeCheck.isIngested(run, files: files([("/S/F02.DNG", 10), ("/S/F03.DNG", 20)])), true, "run of files adds up")

let paths = card.map(\.0)
check(VolumeCheck.isTranscoded(record, paths: paths), false, "nothing transcoded")
record.rendered = ["C0012.MP4"]
check(VolumeCheck.isTranscoded(record, paths: paths), true, "every clip transcoded")
check(VolumeCheck.isTranscoded(record, paths: paths + ["/CLIP/C0013.MP4"]), false, "a clip was not transcoded")
record.renderPending = true
check(VolumeCheck.isTranscoded(record, paths: paths), false, "a transcode is still to run")

// A reel's offload and transcode share a recent row, with a tick for each. Failures don't.
func finishedJob(_ id: String, _ kind: String, _ state: JobState, _ title: String) -> Job {
    var job = Job(id: id, url: "", kind: kind, startedAt: Date(), lastActivity: Date())
    job.state = state
    job.info = JobInfo(title: title)
    return job
}
var rows = RecentRow.group([finishedJob("1", "Render", .succeeded, "K002"), finishedJob("2", "Copy", .succeeded, "K003"),
                            finishedJob("3", "Copy", .succeeded, "K002"), finishedJob("4", "Render", .failed, "K003"),
                            finishedJob("5", "Verify", .succeeded, "K002")])
check(rows.map(\.title), ["K002", "K003", "K003", "K002"], "reel rows keep newest first")
check(rows[0].jobs.count, 2, "offload and transcode merged")
check([rows[0].hasGreenTick, rows[0].hasBlueTick], [true, true], "both ticks")
check([rows[1].hasGreenTick, rows[1].hasBlueTick], [true, false], "offload alone is green only")
check(rows[2].hasBlueTick, false, "a failed transcode earns no blue tick")
check(rows[3].jobs.count, 1, "verify keeps its own row")
rows = RecentRow.group([finishedJob("1", "Render", .succeeded, "K005")])
check([rows[0].hasGreenTick, rows[0].hasBlueTick], [false, true], "transcode alone is blue only")

// Hiding goes by disk UUID, so a second card with the same name stays listed.
let cardOne = VolumeStatus(path: "/Volumes/Untitled", name: "Untitled", key: "UUID-1", freeBytes: 0, totalBytes: 0)
let cardTwo = VolumeStatus(path: "/Volumes/Untitled 1", name: "Untitled", key: "UUID-2", freeBytes: 0, totalBytes: 0)
check([cardOne, cardTwo].visible(hidden: ["UUID-1"]).map(\.path), ["/Volumes/Untitled 1"], "only the chosen card hides")
check([cardOne, cardTwo].visible(hidden: []).count, 2, "nothing hidden")

// Pausing, and leftovers from a crash found by the startup scan.
tracker = Tracker()
started(tracker)
tracker.ingest(state(2, "started", "willSuspend"))
check(tracker.jobs[0].state, .paused, "paused")
tracker.ingest(state(3, "willResume", "started"))
check(tracker.jobs[0].state, .running, "resumed")
tracker.pruneAfterScan(silverstackStarted: nil)
check(tracker.jobs.count, 1, "a silent job survives the startup scan")
check(tracker.jobs[0].isWaiting, true, "nothing logged yet means waiting")
tracker.pruneAfterScan(silverstackStarted: Date())
check(tracker.jobs.isEmpty, true, "job from before Silverstack's launch was cut off")

// A queued job leaves the queue at its first task, but not because a different job moved.
tracker = Tracker()
started(tracker)
started(tracker, id: "second.job", job: "x-coredata://STORE-1/RenderJob/p199")
check(tracker.jobs.map(\.isWaiting), [true, true], "both queued")
tracker.ingest("I \(stamp(2)) <JBX:Z2z.dij> [1] MSG: CopyTaskExecution <a.MP4> [info ] copy [prog ] 7%")
check(tracker.jobs.map(\.isWaiting), [false, true], "only the job that began moved up")
tracker.ingest(state(3, "started", "aborted", "x-coredata://STORE-1/RenderJob/p199"))
check(tracker.jobs[1].isWaiting, false, "a job cancelled while queued leaves the queue")

// Two jobs started together keep their own ids, and frame counts never read as bytes.
tracker = Tracker()
let copy = "x-coredata://STORE-1/CopyJob/p198", render = "x-coredata://STORE-1/RenderJob/p199"
tracker.ingest("I \(stamp(1)) <JBX:aaa.aaa> [1] tasks will be executed in the following buckets:")
tracker.ingest(state(1, "scheduled", "started", copy))
tracker.ingest("I \(stamp(1)) <JBX:bbb.bbb> [1] tasks will be executed in the following buckets:")
tracker.ingest(state(1, "scheduled", "started", render))
check(tracker.jobs.map(\.id), ["aaa.aaa", "bbb.bbb"], "jobs paired in order")
var frames = JobInfo(title: "R")
frames.add(name: "C0013.MP4", size: 636, isDone: false)
tracker.setInfo(frames, forJob: "bbb.bbb")
check(tracker.jobs[1].showsBytes, false, "render sizes are frames")
var overcounted = info(done: 500, doneTasks: 9)
overcounted.alreadyDoneBytes = 500
tracker.setInfo(overcounted, forJob: "aaa.aaa")
check(tracker.jobs[0].doneBytes, 100, "done bytes never pass the total")
check(tracker.jobs[0].doneTasks, 2, "done tasks never pass the total")

check(Format.duration(95), "1m 35s", "minutes")
check(Format.duration(3700), "1h 1m", "hours")
check(Format.bytes(91.26e9), "91.3 GB", "gigabytes")

if failures == 0 { print("All tests passed") } else { exit(1) }
