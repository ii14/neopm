LUA_VERSION = 5.1
LUAROCKS = luarocks --lua-version=$(LUA_VERSION) --tree=.deps

test: .deps/bin/vusted
	@./.deps/bin/vusted

deps: .deps/bin/vusted

.deps/bin/vusted:
	$(LUAROCKS) install vusted

clean:
	$(RM) -rf .deps

.PHONY: test deps clean
