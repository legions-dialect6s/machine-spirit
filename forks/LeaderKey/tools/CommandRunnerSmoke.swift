import Cocoa

@main struct CommandRunnerSmoke {
  static func main() {
    var finished = false
    var ticks = 0
    let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in ticks += 1 }
    CommandRunner.run("/usr/bin/yes x | /usr/bin/head -c 200000; /bin/sleep 0.4") { result in
      print(
        "COMMAND status=\(result.status) capturedBytes=\(result.output.utf8.count) mainRunLoopTicks=\(ticks)"
      )
      precondition(result.status == 0 && result.output.utf8.count == 65_536 && ticks >= 4)
      finished = true
    }
    let limit = Date().addingTimeInterval(5)
    while !finished && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    timer.invalidate()
    precondition(finished)
  }
}
