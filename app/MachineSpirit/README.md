# MachineSpirit.app — the optional board

The app launches as an accessory with no window or Dock icon; `machinespirit://board` opens the single, resizable board (minimum 420×320).
Closing the board removes its view tree and Sheol polling, and returns the app to accessory mode; reopening the running app also summons the board.
While typing in Leader Key, a transparent, click-through graph follows the launcher's screen and current group without taking focus, then fades away when typing ends.
IPC uses `DistributedNotificationCenter`: `com.machinespirit.leader.nav` carries string `state`, `path`, and `screen`; `com.machinespirit.leader.fired` carries string `path` (send with `deliverImmediately: true`).
The legacy `machinespirit://fired?path=…` pulse remains supported without opening the board; hidden graphs have no render clock, and a filesystem watch keeps the live config current.
