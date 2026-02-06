PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

install:
	install -Dm755 claude-usage $(DESTDIR)$(BINDIR)/claude-usage

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/claude-usage

.PHONY: install uninstall
