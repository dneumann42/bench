# TODO

* [ ] New project wizard
** [ ] Project generator
** [ ] Project manager (nimble wrapper and package finder)

* [ ] Module finder
** [ ] Module generator
** [ ] Module migrator

* [ ] Definition finder
* [ ] Jump to definition
* [ ] Nim Syntax Highlighting
* [ ] Reorganize imports
* [ ] Import symbol
* [ ] Type database

Using sqlite and a backend process, the process will update the sqlite when one of the files
of the project change. This will handle vendor folder for development mode. The type database will store a source map of the types within all modules across all of the nim packages in the system.

* [ ] Workbench
