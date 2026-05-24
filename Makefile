SRCS    := $(shell find . -name '*.md' -not -path './_html/*' -not -path './.*/*')
OUTS    := $(patsubst ./%.md, _html/%.html, $(SRCS))
FILTER  := link-html.lua

all: $(OUTS)
	@[ -f _html/README.html ] && mv _html/README.html _html/index.html || true
	@echo "已生成 HTML 到 _html/"

_html/%.html: %.md $(FILTER)
	@mkdir -p $(@D)
	pandoc -s \
		--lua-filter=$(FILTER) \
		-o $@ $<

open: all
	xdg-open _html/index.html

clean:
	rm -rf _html

.PHONY: all open clean
