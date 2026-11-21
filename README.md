# get.projectterminus.org

The Terminus node's install script, one file per version, at `https://get.projectterminus.org/<version>/install.sh`.
A published version never changes. The app's "Add a machine" line checks the script's SHA-256 before it runs it:
compare that digest with this list, which does not come from any instance.

| Version | SHA-256 of install.sh |
| --- | --- |
| 0.35.3 | `b04c372a973e93ad98f0a4dff50486daf4c6f24bdea943d6eb8365114f85c692` |
| 0.35.1 | `ef43924a63717fa5ed78f84f0c615f9731c79f1264ef20edc4bd3aa2d2819edc` |
| 0.33.4 | `dd30c85d05c7fb6340c2bee242fe5e9dd8f1896e8ec8559aae2d87b3a2f00354` |
| 0.33.2 | `99623ffb2b0f9a69d96519cf69a9c3e6ec3b5243aefd243bca72ca905cceb4e8` |

The script is licensed under the Apache License, Version 2.0: see [LICENSE](LICENSE) and [NOTICE](NOTICE).

On Ubuntu 26.04 the script may take Apptainer's package from the node's repository: see
[NOTICE.apptainer](NOTICE.apptainer) for its licences and where its source is.
