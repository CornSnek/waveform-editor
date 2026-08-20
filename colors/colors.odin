//u32be to u32 needs transmute(u32)color_value and not u32(color_value)
package colors

ColorsButton :: struct {
	idle:    u32be,
	hovered: u32be,
	active:  u32be,
}

RED_BUTTON :: ColorsButton{
    idle = 0xcc303066,
    hovered = 0xcc3030ff,
    active = 0xff7f7fff,
}

GREEN_BUTTON :: ColorsButton{
    idle = 0x30cc3066,
    hovered = 0x30cc30ff,
    active = 0x7fff7fff,
}

WELineGraphColors :: struct {
    background_idle: u32be,
    background_highlight: u32be,
    bar_idle: u32be,
    line_idle: u32be,
    bar_hovered: u32be,
    line_hovered: u32be,
    bar_hovered2: u32be,
    line_hovered2: u32be,
    bar_hovered3: u32be,
    line_hovered3: u32be,
}

WE_LINE_GRAPH :: WELineGraphColors {
    background_idle= 0x003f00ff,
    background_highlight= 0x195919ff,
    bar_idle= 0x007f00ff,
    line_idle= 0x00bf00ff,
    bar_hovered= 0x7fff7fff,
    line_hovered= 0xbfffbfff,
    bar_hovered2= 0x000000ff,
    line_hovered2= 0x0000007f,
    bar_hovered3= 0xafffafff,
    line_hovered3= 0xdfffdfff,
}