use common::{
    icons::outline::Shape as Icon,
    state::{scope_ids::ScopeIds, Action, State},
};
use dioxus::prelude::*;
use dioxus_desktop::use_eval;
use extensions::{export_extension, Details, Extension, Location, Meta, Type};
use kit::{
    components::nav::{Nav, Route},
    elements::{button::Button, label::Label},
};
use once_cell::sync::Lazy;

// These two lines are all you need to use your Extension implementation as a shared library
static EXTENSION: Lazy<LedTasso> = Lazy::new(|| LedTasso {});
export_extension!(EXTENSION);

pub struct LedTasso;

impl LedTasso {
    fn get_quotes() -> Vec<&'static str> {
        vec![
            "Look at it out there. It looks like a Renaissance painting portraying masculine melancholy.",
            "One more person says something that me and Beard don't understand, I'm gonna have one of my son's classic temper tantrums.",
            "This woman is strong, confident, and powerful. Boss, I tell you, I'd hate to see you and Michelle Obama arm wrestle, but I wouldn't be able take my eyes off of it, either.",
            "I do love a locker room. It smells like potential.",
            "I believe in Communism. Rom-communism, that is. If Tom Hanks and Meg Ryan can go through some heartfelt struggles and still end up happy, then so can we.",
            "I've never been embarrassed about having streaks in my drawers. You know, it's all part of growing up.",
            "Taking on a challenge is a lot like riding a horse, isn't it? If you're comfortable while you're doing it, you're probably doing it wrong.",
            "If that’s a joke, I love it. If not, can’t wait to unpack that with you later.",
            "I always figured that tea was just gonna taste like hot brown water. And you know what? I was right. Yeah, it's horrible. No, thank you.",
            "Tea is horrible. Absolute garbage water. I don't know why y'all do that.",
            "If you would have told me that I’d be drinking tea at 3 o’clock every day, about a year ago… I would have punched you in the mouth.",
            "Be honest with me. It's a prank, right? The tea? Like when us tourist folks aren't around, y'all know it tastes like garbage? You don't love it. It's pigeon sweat.",
            "I do. But more importantly, I think they need to believe in themselves. You know?",
            "Back where I'm from, you try to end a game in a tie; well, that might as well be the first sign of the apocalypse.",
            "You got Ronaldo and the fellow who bends it like himself.",
            "We're gonna call this drill 'The Exorcist' 'cause it's all about controlling possession.",
            "You know what the happiest animal on Earth is? It's a goldfish. Y'know why? It's got a 10-second memory. Be a goldfish.",
            "If the internet has taught us anything, it's that sometimes it's easier to speak our minds anonymously.",
            "I'm not sure what y'all's smallest unit of measurement is here, but that's about how much headway I made.",
            "She's got some fences, alright, but you just gotta hop over 'em.",
            "I'm gonna put it the same way the US Supreme Court did back in 1964 when they defined pornography. It ain't easy to explain, but you know it when you see it.",
            "I think I literally have a better understanding of who killed Kennedy than what is offside... It was the mob.",
            "Jamie, I think that you might be so sure that you're one in a million, that sometimes you forget that out there, you're just 1 of 11. And if you just figure out someway to turn that 'me' into 'us'...the sky's the limit for you.",
            "I come bearing sweet treats to numb the sting of defeat.",
            "I always feel so bad for the cows, but you gotta do it; otherwise, they get lost. That was a branding joke. If we were in Kansas right now, I'd just be sitting here waiting for you to finish laughing.",
            "For me, success is not about the wins and losses. It's about helping these young fellas be the best versions of themselves on and off the field.",
            "If I didn't have any confidence, I never would've worn pajamas to my prom and ended up in jail the rest of that night.",
            "You two knuckleheads have split our locker room in half. And when it comes to locker rooms, I like 'em just like my mother's bathing suits. I only wanna see 'em in one piece, you hear?",
            "Here's an idea that's gonna help a little or hurt a whole lot. Who needs a drink?",
            "You know how they say that 'youth is wasted on the young'? Well, I say don't let the wisdom of age be wasted on you. I just came up with that. I feel pretty good about it.",
            "It's like a muffin, except it sucks all the spit out of your mouth.",
            "Coach Beard's views on romantic relationships are not too dissimilar from his views on cooking steak. You know, you spend any more than five minutes on one — it loses its flavor.",
            "I gotta say, man, sometimes you remind me of my grandma with the channel hopper. You just push all the wrong buttons.",
            "I feel like we fell out of a lucky tree, hit every branch on the way down, ended up in a pool full of cash and Sour Patch Kids.",
            "What I can tell you is that with the exception of the wit and wisdom of Calvin and Hobbes, not much lasts forever.",
            "I think one of the neatest things about being a coach is the connection you get to make with your players. That's a loss that hits me a lot harder and is gonna stay with me a lot longer than anything that happens while playing a game on a patch of grass.",
            "Sounds to me like someone's trapped inside life's most complicated shape: a love triangle. Second place of course is the 'I just walked in on my mother-in-law changing into her swimsuit' dodecahedron.",
            "It's just a group of people who care, Roy. Not unlike folks at a hip-hop concert whose hands are not in the air.",
            "Well, as my doctor told me when I got addicted to fettuccine Alfredo, that's a little rich for my blood.",
            "Guys have underestimated me my entire life. And for years, I never understood why. It used to really bother me. But then one day, I was driving my little boy to school, and I saw this quote by Walt Whitman, and it was painted on the wall there. It said, 'Be curious, not judgmental.' I like that.",
            "This is a sad moment right here. For all of us. And there ain't nothing I can say, standing in front of you right now, that can take that away. But please do me this favor, will you? Lift your heads up and look around this locker room. Yeah? Look at everybody else in here. And I want you to be grateful that you're going through this sad moment with all these other folks. Because I promise you, there is something worse out there than being sad, and that is being alone and being sad. Ain't nobody in this room alone. Let's be sad now. Let's be sad together. And then we can be a gosh-darn goldfish. Onward. Forward.",
            "Look, we are not playing for a tie. Ain't nobody here gonna kiss their sister...which is an American phrase that I'm now realizing does not exist here, and that's good, 'cause it's creepy, and I hate it myself; I don't know why I said it.",
            "There's two buttons I never like to hit, alright? And that's 'panic' and 'snooze.'",
            "It's funny to think about the things in your life that can make you cry just knowing that they existed, can then become the same thing that make you cry knowing that they're now gone.",
            "I haven't seen someone that disappointed to see me since I wore a red baseball cap to a Planned Parenthood fundraiser.",
            "I shouldn't bring an umbrella to a brainstorm.",
            "Hey, you two are like Frank Sinatra and Ava Gardner, you know? Or, uh, Frank Sinatra and Mia Farrow. Or Frank and... Actually, you know what? I'm starting to realize that Ol' Blue Eyes might've skewed mercurial.",
            "There's a bunch of crazy stuff on Twitter. Heck, someone made an account for my mustache.",
            "I've never met someone who doesn't eat sugar. Only heard about 'em, and they all live in this godless place called Santa Monica.",
            "Doing the right thing is never the wrong thing.",
            "You are more mysterious than David Blaine reading a Sue Grafton novel at Area 51."
        ]
    }

    fn render_selector<'a>(&self, cx: &'a ScopeState, hide: &'a UseState<bool>) -> Element<'a> {
        //println!("render emoji selector");
        let state = use_shared_state::<State>(cx)?;

        #[cfg(not(target_os = "macos"))]
        let eval = use_eval(cx);

        let focus_script = r#"
            var emoji_selector = document.getElementById('emoji_selector');
            emoji_selector.focus();
        "#;

        cx.render(rsx! (
            div {
                id: "led_tasso",
                tabindex: "0",
                div {
                    id: "scrolling",
                    img {
                        src: "https://preview.redd.it/1kttqdu1tt081.png?width=640&crop=smart&auto=webp&s=00b3a62af0a30cf28d0a88267f46856d3e9d6391",
                    },
                    for quote in Self::get_quotes() {
                        rsx!(Button {
                            text: quote.into(),
                            onpress: move |val| {
                                let c =  match state.read().get_active_chat() {
                                    Some(c) => c,
                                    None => return
                                };
                                let draft: String = c.draft.unwrap_or_default();
                                let new_draft = format!("{draft} {}", quote.clone());
                                state.write_silent().mutate(Action::SetChatDraft(c.id, new_draft));
                                if let Some(scope_id_usize) = state.read().scope_ids.chatbar {
                                    cx.needs_update_any(ScopeIds::scope_id_from_usize(scope_id_usize));
                                };
                                // Hide the selector when clicking an emoji
                                hide.set(true);
                            }
                        })
                    }
                }
            },
        ))
    }
}

impl Extension for LedTasso {
    fn details(&self) -> Details {
        Details {
            location: Location::Chatbar,
            ext_type: Type::IconLaunched,
            meta: Meta {
                name: "led_tasso",
                pretty_name: "Ted Lasso Quotes",
                description: "Browse a selection of Ted Lasso quotes.",
                author: "Satellite <devs@satellite.im>",
            },
        }
    }

    fn stylesheet(&self) -> String {
        include_str!("./style.css").to_string()
    }

    fn render<'a>(&self, cx: &'a ScopeState) -> Element<'a> {
        let styles = self.stylesheet();
        let display_selector = use_state(cx, || false);

        cx.render(rsx! (
            style { "{styles}" },
            // If enabled, render the selector popup.
            display_selector.then(|| self.render_selector(cx, display_selector)),
            div {
                // Render standard (required) button to toggle.
                Button {
                    icon: Icon::LightBulb,
                    onpress: move |_| {
                        display_selector.set(!display_selector.clone());
                    }
                }
            }
        ))
    }
}
