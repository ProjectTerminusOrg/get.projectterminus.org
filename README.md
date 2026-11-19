# get.projectterminus.org

The Terminus node's install script, one file per version, at `https://get.projectterminus.org/<version>/install.sh`.
A published version never changes. The app's "Add a machine" line checks the script's SHA-256 before it runs it:
compare that digest with this list, which does not come from any instance.

| Version | SHA-256 of install.sh |
| --- | --- |
| 0.33.4 | `dd30c85d05c7fb6340c2bee242fe5e9dd8f1896e8ec8559aae2d87b3a2f00354` |
| 0.33.2 | `99623ffb2b0f9a69d96519cf69a9c3e6ec3b5243aefd243bca72ca905cceb4e8` |

The script is licensed under the Apache License, Version 2.0: see [LICENSE](LICENSE) and [NOTICE](NOTICE).
