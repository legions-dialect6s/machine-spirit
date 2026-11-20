-- Preserve the existing launcher entry point. ms sets the final frame once.
on run argv
  try
    set delta to (item 1 of argv) as integer
    do shell script (quoted form of (POSIX path of (path to home folder) & "bin/ms")) & " win resize --delta " & delta
  end try
end run
