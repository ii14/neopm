# hack to make "require" work for the root directory
PARENT = $(shell readlink -f ..)
LUA_PATH = $(shell lua -e 'print(package.path)');$(PARENT)/?.lua;$(PARENT)/?/init.lua

.PHONY: test
test:
	@vusted
