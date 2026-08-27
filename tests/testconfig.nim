import std/[options, os, tables, unittest]
import ../src/config, ../src/utils

suite "matchConfigSection":
  # canonical rule from src/pacman/ini.c: '[' first char + ']' last char,
  # name is the verbatim interior.

  test "plain and empty sections":
    check matchConfigSection("[options]").get == "options"
    check matchConfigSection("[]").get == ""

  test "brackets inside the name stay verbatim":
    check matchConfigSection("[a][b]").get == "a][b"
    check matchConfigSection("[nested]x]").get == "nested]x"

  test "trailing junk before a non-bracket end disqualifies":
    for s in ["[core] junk", "[options] # note"]:
      check matchConfigSection(s).isNone

suite "readConfigFile end-to-end on fixture":
  let confPath = getTempDir() / "pakku-test-pacman.conf"
  # writeLines emits real control characters: the fixture line ends with a
  # true TAB, which upstream `readLine().strip()` removes before parsing --
  # so the value arrives as "linux", matching production behavior.
  var f = open(confPath, fmWrite)
  f.write("[options]\n",
    "HoldPkg = gcc glibc\n",
    "IgnorePkg = linux\t\n",
    "X = y\n",
    "[weird]\n",
    "bad line here\n",
    "[kernel]\n")
  f.close()

  test "sections, accumulations and fallback lines parse identically":
    let (table, wasError) = readConfigFile(confPath)
    let sectionCount = table.len
    let options = table["options"][]
    let kernelEntries = table["kernel"][].len
    check not wasError
    check sectionCount == 3  # options, weird, kernel
    check options["HoldPkg"] == "gcc glibc"
    check options["IgnorePkg"] == "linux"
    check options["X"] == "y"
    # non-keyval line inside a section falls into `category[line] = ""`
    check table["weird"]["bad line here"] == ""
    check kernelEntries == 0
