-- UTF-8 layout and rich text; no native resources or input.
local M = {}
-- Whole-glyph viewport: never split UTF-8 or draw outside the allotted width.
function M.flow(value, width, size, time, measure)
    local glyphs = {}
    for glyph in string.gmatch(tostring(value), "[%z\1-\127\194-\244][\128-\191]*") do
        glyphs[#glyphs + 1] = glyph
    end
    local widths, total = {}, 0
    for i, g in ipairs(glyphs) do
        widths[i] = (measure and measure(g, size)) or size * 0.62
        total = total + widths[i]
    end
    if total <= width then
        return tostring(value), false
    end
    local last = #glyphs
    local tail = 0
    while last > 1 and tail + widths[last] <= width do
        tail = tail + widths[last]
        last = last - 1
    end
    last = math.min(#glyphs, last + 1)
    local travel = math.max(0, last - 1)
    local duration = travel * 0.25
    local phase = math.max(0, time or 0) % (duration * 2 + 3)
    local offset = phase < 1.5 and 0
        or phase < 1.5 + duration and math.floor((phase - 1.5) / 0.25)
        or phase < 3 + duration and travel
        or travel - math.floor((phase - 3 - duration) / 0.25)
    local first = math.max(1, math.min(last, offset + 1))
    local visible, used = {}, 0
    for i = first, #glyphs do
        if used + widths[i] > width then
            break
        end
        visible[#visible + 1] = glyphs[i]
        used = used + widths[i]
    end
    return table.concat(visible), true
end
-- Renderer-independent lightweight rich text: paragraphs, lists, headings and emphasis.
function M.rich(value, width, size, measure)
    local lines = {}
    value = string.gsub(tostring(value or ""), "\r\n", "\n")
    for paragraph in string.gmatch((value .. "\n"), "(.-)\n") do
        local heading, body = string.match(paragraph, "^(#+)%s+(.+)$")
        local font = heading and size + 3 or size
        body = body or paragraph
        body = string.gsub(body, "^%s*[-*]%s+", "• ")
        local spans, line, used = {}, {}, 0
        local strong, emphasis = false, false
        local function flush()
            lines[#lines + 1] = { spans = line, size = font }
            line = {}
            used = 0
        end
        local function add(word, style)
            local glyphs = {}
            for glyph in string.gmatch(word, "[%z\1-\127\194-\244][\128-\191]*") do
                glyphs[#glyphs + 1] = glyph
            end
            for _, glyph in ipairs(glyphs) do
                local gw = (measure and measure(glyph, font)) or font * 0.62
                if used + gw > width and #line > 0 then
                    flush()
                end
                if not (glyph == " " and #line == 0) then
                    local last = line[#line]
                    if last and last.style == style then
                        last.text = last.text .. glyph
                        last.width = last.width + gw
                    else
                        line[#line + 1] = { text = glyph, style = style, width = gw }
                    end
                    used = used + gw
                end
            end
        end
        local index = 1
        while index <= #body do
            if string.sub(body, index, index + 1) == "**" then
                strong = not strong
                index = index + 2
            elseif string.sub(body, index, index) == "*" then
                emphasis = not emphasis
                index = index + 1
            else
                local stop = string.find(body, "*", index, true) or (#body + 1)
                local chunk = string.sub(body, index, stop - 1)
                for word in string.gmatch(chunk, "%S+%s*") do
                    local ww = 0
                    for glyph in string.gmatch(word, "[%z\1-\127\194-\244][\128-\191]*") do
                        ww = ww + ((measure and measure(glyph, font)) or font * 0.62)
                    end
                    if used + ww > width and #line > 0 then
                        flush()
                    end
                    add(
                        word,
                        heading and "heading"
                            or strong and "strong"
                            or emphasis and "emphasis"
                            or "plain"
                    )
                end
                index = stop
            end
        end
        flush()
    end
    return lines
end
function M.width(value,size,measure)
    local width=0
    for glyph in string.gmatch(tostring(value),"[%z\1-\127\194-\244][\128-\191]*") do width=width+(measure and measure(glyph,size) or size*.62) end
    return math.max(width,measure and measure(tostring(value),size) or 0)
end
return M
