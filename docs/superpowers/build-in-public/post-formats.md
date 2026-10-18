# Reusable Post Formats

Use these as draft shells. Fill them from merged work, devlogs, release notes,
or real screenshots. Delete any section that does not have proof.

## Weekly Build Note

Best for: GitHub/devlog mirrors, X, Bluesky, Mastodon.

```markdown
This week in [App]:

- Shipped: [specific thing]
- Fixed: [specific thing]
- Improved: [specific thing]

Proof/details: [link]
```

Rules:

- Keep to three bullets unless the week truly needs more.
- Use exact dates if the post is not going out during the week it describes.
- Link to a devlog, release note, PR, screenshot, or build note.

## Problem/Solution Note

Best for: Reddit or community posts, only when the problem is genuinely useful
to the community.

```markdown
I kept running into [specific problem] while [real context].

I built [App] to handle it by [specific mechanism].

What is working now:

- [shipped proof]
- [shipped proof]

What is still rough:

- [honest limitation]
- [honest limitation]

I am looking for feedback on [specific question].
```

Rules:

- Lead with the human problem, not the app name.
- Include limitations.
- Ask one specific feedback question.
- Do not post if there is no time to reply.

## Demo Clip Caption

Best for: X, Bluesky, Mastodon, TikTok only if video becomes repeatable.

```markdown
[App] demo: [thing shown in the clip].

Why it matters: [one practical outcome].

Built this week: [proof item or date].
```

Rules:

- The caption must describe what the viewer can actually see.
- Do not rely on audio-only context.
- Mention prototype/beta status if visible polish is not final.

## Launch-Day Post

Best for: Public launch, App Store/TestFlight availability.

```markdown
[App] is now [available/in public beta].

It is for [audience] who need [specific job].

What it does today:

- [shipped capability]
- [shipped capability]
- [shipped capability]

Where to try it: [link]
How it was built: [devlog/repo link]
```

Rules:

- No roadmap bullets in "does today."
- Pricing/subscription wording must match the live App Store or TestFlight copy.
- Include privacy/licensing notes only if relevant to the decision to try it.

## Monthly Ledger

Best for: Umbrella recap across apps.

```markdown
Monthly build ledger: [Month]

[App 1]
- Shipped:
- Fixed:
- Learned:

[App 2]
- Shipped:
- Fixed:
- Learned:

Next month:
- [specific focus]
```

Rules:

- Keep the "learned" line concrete.
- State what did not ship when that matters.
- Link each app to its public proof surface.

## Reply Bank

Use these only as starting points; rewrite them in context.

```markdown
Thanks for taking a look. The current build does [specific shipped thing], while
[specific thing] is still planned rather than shipped.
```

```markdown
That is a fair concern. The reason I chose [decision] was [concrete constraint].
I am watching for [specific failure mode].
```

```markdown
I do not want to overstate this: right now it works for [known case]. The next
test is [specific next case].
```
