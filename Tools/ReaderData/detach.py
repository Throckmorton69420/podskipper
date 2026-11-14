#!/usr/bin/env python3
"""Pass 65: start a long job so nothing but a restart of the Mac (or `kill`) ends it.

    detach.py <log file> <command…>

`nohup … &` from a terminal tab wasn't enough (14 Nov: route 1 died when the tab that started it closed): the
job stayed in the tab's session. Here the job forks, leaves that session (setsid), takes no input, writes to
<log file>, and its process id goes to <log file>.pid. Run from anywhere: the Terminal app, a tab, the chat.
"""
import os
import sys


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    log, cmd = os.path.abspath(sys.argv[1]), sys.argv[2:]
    os.makedirs(os.path.dirname(log), exist_ok=True)
    if os.fork():
        os._exit(0)                  # the caller returns at once
    os.setsid()                      # a session of its own: closing the tab or app that started it can't end it
    if os.fork():
        os._exit(0)                  # not a session leader, so it can never get a terminal again
    fd = os.open(os.devnull, os.O_RDONLY)
    os.dup2(fd, 0)
    out = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    os.dup2(out, 1)
    os.dup2(out, 2)
    open(log + ".pid", "w").write(str(os.getpid()))
    os.execvp(cmd[0], cmd)


if __name__ == "__main__":
    main()
