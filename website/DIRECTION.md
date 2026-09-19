# Direction: the Mac, already at work

Mode: Persuade. This is a code-led replacement of the rejected website.

## User-pinned authority

CodexBar's wide Mac-display composition is the explicit reference. The user
rejected the ribbon artwork, mint/silver site colors, and low-resolution product
screenshots. The replacement uses HTML/CSS for the real app interface, neutral
black/white/charcoal for the site, and the original app colors only inside its UI.
This pinned brief overrides open-ended concept selection. The concept seed ran;
its random direction is not authority over the user's named reference.

## First viewport

The user-selected second mock is the visual authority for the hero: a ChatGPT
window behind the CodexSwitch menu, with a matching account profile in both.
A slim masthead sits above a left-cropped Mac. Its top-right corner remains visible,
while its left and bottom hardware extend out of view. The native menu stays upright
and fully interactive. Copy is outside the device on the right: the approved Korean
headline is “ChatGPT 계정 전환, / 메뉴바에서 바로.” The English route says
“Switch ChatGPT accounts. / From your menu bar.” Supporting copy explicitly explains
that ChatGPT reopens with the selected account. A coded ChatGPT window sits behind
the 340px app menu, with its selected profile visible at bottom left. At 900px and
below, copy precedes the cropped Mac, then the two windows stack at readable sizes.
The user's supplied two-toggle control-center shape replaces the former sliders icon.

## Signature interaction

The menu-bar icon opens/closes the app menu. The account submenu switches among
three explicitly illustrative accounts and updates the selected email, remaining
usage, reset data, and ChatGPT profile. ChatGPT closes and reopens with the selected
account; disabling “Open ChatGPT after switching” leaves a manual Open button.
The underlined play CTA opens the menu and focuses the next account. The native
switch command has a visible “Try it” hint and two brief highlight pulses, removed
once used. A compact live status explains the result only after interaction; there
is no extra CTA or reserved feedback height below the windows.
Both native-looking toggles work locally. Refresh gives
short-lived feedback without making requests. Demo actions never touch real login
information. All controls support keyboard operation and reduced motion.

## Visitor path

Native product in context; a working account-switch demonstration; focused usage
and reset-credit explanations; concise installation and FAQ; a plain download
close. Retain Korean/English, light/dark, release links, and product facts.

## Motion and finish

Menu and submenu disclosure keep their authored motion. At the user's request,
below-the-fold content now reveals once on scroll with a 24px rise and 600ms fade.
Feature pairs and installation steps stagger by 70ms, up to 140ms. Initially visible
content, reduced motion, keyboard focus, printing, and no-JavaScript visits stay readable.
App text uses system UI to match macOS, tabular numerals for usage.
Site typography is neutral, sharp, with tracking no tighter than -0.04em.
No generated imagery. The existing app icon remains the only raster asset.

The first menu entrance takes 420ms; subsequent openings take 220ms and exits
110ms. Repeated input resumes from the current frame. Account data changes use
a 240ms opacity acknowledgment and the usage bar changes through a 380ms clip
transition without reflow. The menu slot keeps its height when closed. Reduced
motion uses an 80ms opacity-only alternative and immediate usage-bar changes.
ChatGPT exits in 160ms, pauses 150ms, and enters over 420ms. Rapid selection cancels
the previous transition; only the newest account completes. Reduced motion removes
the scale and pause, retaining 80ms fades. No infinite effects.

## Language

An inline head script resolves language before body rendering. Explicit `?lang=ko`
or `?lang=en` choices persist locally. Direct `/en/` links remain English. Root visits
use a saved choice or the primary browser language (Korean → Korean, otherwise English).
Query and hash are retained. Explicit language links still work if storage is blocked.

## Risk

Web components can closely match native geometry and behavior, but are an
illustrative website demo, not macOS system windows or real account controls.
The CTA and example.com addresses establish the demo context. Per the user's copy
direction, do not add an explanatory disclaimer or repeat what the controls already say.
