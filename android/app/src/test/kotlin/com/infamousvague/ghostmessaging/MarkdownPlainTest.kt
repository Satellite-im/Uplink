package com.infamousvague.ghostmessaging

import org.junit.Assert.assertEquals
import org.junit.Test

/** A notification's preview without the formatting markers ([MarkdownPlain]), as lib/message_format.dart's plain. */
class MarkdownPlainTest {
    @Test fun theMarkersGo() {
        assertEquals("bold and it x c", MarkdownPlain.strip("**bold** and *it* ~~x~~ `c`"))
        assertEquals("quoted\nreply", MarkdownPlain.strip("> quoted\nreply"))
        assertEquals("code", MarkdownPlain.strip("```\ncode\n```"))
        assertEquals("docs", MarkdownPlain.strip("[docs](https://gogho.st/docs)"))
        assertEquals("both", MarkdownPlain.strip("***both***"))
        assertEquals("a b c", MarkdownPlain.strip("*a **b** c*"))
        assertEquals("italic", MarkdownPlain.strip("_italic_"))
    }

    @Test fun spoilersAreHidden() {
        assertEquals("the end: ▒▒▒▒▒▒▒", MarkdownPlain.strip("the end: ||he dies||"))
        assertEquals("▒".repeat(8), MarkdownPlain.strip("||a very long secret indeed||"))
    }

    @Test fun everydayWordsStay() {
        assertEquals("2*3*4 and snake_case", MarkdownPlain.strip("2*3*4 and snake_case"))
        assertEquals("https://x.com/a_b_c_", MarkdownPlain.strip("https://x.com/a_b_c_"))
        assertEquals("https://x.com/a_b", MarkdownPlain.strip("**https://x.com/a_b**"))
        assertEquals("`**not bold**`".trim('`'), MarkdownPlain.strip("`**not bold**`"))
        assertEquals("5 > 3", MarkdownPlain.strip("5 > 3"))
        assertEquals("*not* it", MarkdownPlain.strip("\\*not\\* it"))
        assertEquals("[paypal.com](https://evil.example)", MarkdownPlain.strip("[paypal.com](https://evil.example)"))
        assertEquals("hello", MarkdownPlain.strip("hello"))
    }
}
