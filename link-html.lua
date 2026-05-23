-- pandoc Lua filter: rewrite .md links to .html for HTML output
function Link(el)
    if el.target:match('%.md$') then
        el.target = el.target:gsub('%.md$', '.html')
    end
    return el
end
