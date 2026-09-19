---
name: CodexSwitch Website
description: A quiet, native Mac context for an account-switching utility.
colors:
  background: '#0b0c0e'
  surface: '#111215'
  text: '#f1f2f3'
  muted: '#96989e'
  line: '#27292e'
  menu: '#27282c'
  menu-text: '#f1f1f3'
  menu-muted: '#b0b1b6'
  usage: '#64c5b4'
  switch: '#287ced'
typography:
  display:
    fontFamily: '-apple-system, BlinkMacSystemFont, Helvetica Neue, Apple SD Gothic Neo, sans-serif'
    fontSize: 'clamp(36px, 3.6vw, 62px)'
    fontWeight: 650
    lineHeight: 1.23
    letterSpacing: '-0.04em'
  headline:
    fontFamily: '-apple-system, BlinkMacSystemFont, Helvetica Neue, Apple SD Gothic Neo, sans-serif'
    fontSize: '38px'
    fontWeight: 600
    lineHeight: 1.28
  body:
    fontFamily: '-apple-system, BlinkMacSystemFont, Helvetica Neue, Apple SD Gothic Neo, sans-serif'
    fontSize: '14px'
    lineHeight: 1.85
  mono:
    fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace'
    fontSize: '12px'
    fontWeight: 600
rounded:
  button: '999px'
  menu: '11px'
  proof: '16px'
spacing:
  compact: '8px'
  menu-inset: '16px'
  story-gap: '48px'
components:
  primary-button:
    backgroundColor: '{colors.text}'
    textColor: '#151619'
    rounded: '{rounded.button}'
    padding: '13px 22px'
  native-menu:
    backgroundColor: '{colors.menu}'
    textColor: '{colors.menu-text}'
    rounded: '{rounded.menu}'
    width: '372px'
---

# Design System: CodexSwitch Website

## Overview

**Creative North Star: "The Mac, already at work"**

The website places the product in the familiar context of a Mac. Quiet neutral surfaces,
native typography, thin dividers, and precise menu density keep the utility itself legible.
This document applies to `website/`; it does not redefine the native application's design.

The user explicitly rejected the decorative generated ribbon, site-wide mint palette,
and low-resolution app screenshots. The binding reference is codexbar.app and the binding
product reference is the existing Swift implementation. The user requested a direct coded
reproduction of the Mac and application; this is the authority for the native system font
and the display frame.

**Key Characteristics:**
- Neutral page surfaces with readable secondary text.
- Product UI rendered as text and controls, not a flattened image.
- Color belongs to the original app mark and meaningful in-app states.

## Colors

The page uses charcoal and white. The light theme reverses the neutral surfaces without
changing the hierarchy. Its exact values live alongside the dark tokens in global.css.

### Primary
- **Soft White:** headings, primary download action, and emphasis on dark surfaces.

### Secondary
- **Usage Aqua:** the actual app's remaining-usage bar only.
- **System Blue:** enabled app switches and focused account menu items only.

### Neutral
- **Charcoal:** page and screen backgrounds.
- **Menu Graphite:** elevated native controls.
- **Secondary Gray:** supporting copy and native metadata.

**The Product Color Rule.** Preserve the existing icon colors; do not spread them into
large decorative page backgrounds.

## Typography

Display and body use the operating system's native sans serif. This is an explicit Mac
fidelity choice. Durations and account metadata use system monospace. The hero is large
and compact; body copy is restrained, with more line height. Native UI keeps its source
hierarchy, including the 40px remaining-usage value.

Mobile headlines reduce to 26–43px according to available width; body copy remains text,
not a scaled-down screenshot. Korean uses keep-all wrapping and balanced headings.

## Layout

Body sections use a centered 1100px container. The user-selected second visual concept
places a cropped Mac on the left (56vw) and independent marketing copy on the right.
The device extends beyond the left edge; its top-right corner remains visible. The
native menu is 340px wide beside a coded ChatGPT window. The profile remains visible
at the bottom left, and at wide desktop sizes the account submenu opens left inside
the display. At 900px and below, copy comes first followed by the left-cropped display,
with a readable unscaled menu and a compact ChatGPT result window below it.

Content sections use 112px vertical spacing, reduced to 72px on mobile. Feature proofs
use three equal columns in a 1280px feature container, installation steps use an ordered sequence, and FAQ uses plain
full-width disclosure rows. Grid children allow shrinking at 320px.

The approved feature section pairs a heading and short description with a 3:2
landscape-backed native UI excerpt below. Order: account switching, remaining usage,
reset credits. Account rows follow StatusMenuController.swift: a disabled current
account with a checkmark, names, remaining usage and query age, plus a blue highlighted
alternative. No avatars, profile footer, or repeated trial action. Forest, mountains,
and lake images are decorative backdrops; all product text and icons remain HTML/SVG.
At tablet sizes descriptions sit beside the excerpts; phones use one vertical column.

## Elevation & Depth

Depth belongs to the device rim and native floating menu. The page itself stays flat.
Native menus use a diffuse shadow (`0 18px 40px #00000036, 0 3px 8px #0000001c`) and a thin
translucent border. The account submenu sits above the menu that owns it.

## Shapes

Download buttons are pills. Native menus have compact rounded corners; usage bars and
switches are capsules. The display's visible top-right rim and partially cropped notch establish the Mac
context requested by the user. Brand geometry is copied from the app, not newly invented.

UI icons use the original Framework7 SVG paths; Apple and GitHub use filled Simple
Icons brand silhouettes. Do not substitute outline interpretations of those logos.
Icons inherit text color directly and render without an icon font. The battery's
viewBox crops unused vertical space so its native horizontal silhouette occupies
the intended 26 × 15px status-bar slot. Menu command icons use 16px slots; header
GitHub uses 20px. No paths are redrawn or approximated. The control-center icon uses the original two-toggle
SVG from SVG Repo (348311, CC0), with currentColor and native filled styling. Its source
and license are recorded beside the asset; it is not an Apple-supplied SF Symbols export.
The ChatGPT preview uses the original OpenAI vector from Simple Icons 13.21.0 (CC0).
Native window controls retain the familiar red/yellow/green traffic-light colors.

## Components

### Download buttons

White on dark, charcoal on light. Hover reduces opacity, active moves by one pixel,
and keyboard focus uses a visible outline. The link targets the current GitHub release.

### Native menu

Compact, source-derived spacing and type. Account switching updates the visible email,
usage, reset duration, and credits. Account submenu supports arrows, Home/End, Escape,
selection, focus return, and outside-click dismissal. The website uses synthetic data.

The initial menu entrance takes 420ms. Open and close transitions take 220ms and
110ms, using `cubic-bezier(0.16, 1, 0.3, 1)` and a top-edge transform origin.
Interrupted transitions resume at the current frame; exiting menus become inert
immediately. The surrounding display keeps its height while the menu is hidden.
Account data acknowledges a change through opacity over 240ms. The usage fill
uses a 380ms clip-path transition, avoiding animated layout dimensions.
Reduced motion substitutes 80ms opacity feedback and immediate bar changes.

### ChatGPT account-switch experience

The hero's underlined play CTA opens the account menu and focuses a different account.
The native “Switch account” row has a small “Try it” label and two finite highlight
pulses; interaction removes both. Choosing an account closes the ChatGPT preview
(160ms), then opens it (420ms after a 150ms pause) with the matching name and email.
The profile receives a brief acknowledgment and a live status confirms the account.
Only the latest selection completes if inputs interrupt the transition. Reduced
motion uses 80ms opacity changes without scale or delay. On narrow screens, the
result scrolls into view only when outside the viewport. Disabling automatic reopen
keeps ChatGPT closed and exposes a manual Open button clear of the native menu.

### Switches

Native checkbox semantics with a compact visual track. Checked state is blue. Focus is
shown around the visual track. Movement is disabled under reduced motion; a short
color transition preserves feedback about the new state.

### Navigation and FAQ

The header keeps branding, theme, language, GitHub, and download controls; section
navigation is omitted. Mobile keeps its existing compact controls. FAQ uses native
details/summary so it remains functional without client JavaScript.

### Scroll entrances

At the user's request, below-the-fold content fades in while rising 24px over 600ms,
using the existing ease-out curve. Feature pairs and installation steps stagger by
70ms, capped at 140ms. Each group reveals once. Initially visible content stays visible;
keyboard focus, reduced motion, printing, and pages without JavaScript expose content
immediately. The hero and app demo retain their own interaction timing.

## Do's and Don'ts

### Do:
- **Do** use actual product structure and native proportions for app demonstrations.
- **Do** keep all marketing content visible without JavaScript and under reduced motion.
- **Do** use example.com accounts for the demo and keep feedback about changed state brief.
- **Don't** add disclaimers explaining that the demo does not affect real accounts; the user explicitly rejected that redundant copy.

### Don't:
- **Don't** use screenshot crops as the product UI.
- **Don't** add wallpaper to the hero; landscape backdrops are confined to the user-approved feature previews.
- **Don't** turn the existing app's small status accents into the page palette.
