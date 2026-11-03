"""Generates docs/diagrams/architecture.svg (deployment architecture)."""

import sys

W, H = 1400, 960
out: list[str] = []

# palette (works on GitHub light and dark because the SVG has its own white background)
INK = "#1f2933"
MUTED = "#52606d"
ACCOUNT = "#fff8eb"
ACCOUNT_STROKE = "#d69e2e"
VPC = "#eef6ff"
VPC_STROKE = "#2b6cb0"
PUB = "#fdecec"
PUB_STROKE = "#c53030"
PRIV = "#f4fbf6"
PRIV_STROKE = "#2f855a"
BOX = "#ffffff"
SVC = "#ffffff"
EXT = "#f2f0fb"
EXT_STROKE = "#6b46c1"
ARROW = "#2d3748"
ACCENT = "#c05621"

# ownership colors (left stripe on each box)
OWN = {
    "platform": "#2b6cb0",  # customer platform team
    "ops": "#2f855a",  # customer operations
    "app": "#c05621",  # application team (FDE builds, customer app team owns after hand-over)
    "vendor": "#6b46c1",  # external vendor
    "sec": "#b7791f",  # customer security
}


def esc(t: str) -> str:
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def rect(x, y, w, h, fill, stroke, rx=10, dash=None, sw=1.5):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    out.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{d}/>')


def text(x, y, s, size=13, weight="normal", color=INK, anchor="start", italic=False):
    st = ' font-style="italic"' if italic else ""
    out.append(
        f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" fill="{color}" text-anchor="{anchor}"{st}>{esc(s)}</text>'
    )


def box(x, y, w, h, title, lines=(), owner=None, fill=BOX, stroke="#a0aec0", title_size=14):
    rect(x, y, w, h, fill, stroke)
    if owner:
        out.append(f'<rect x="{x}" y="{y}" width="6" height="{h}" rx="3" fill="{OWN[owner]}"/>')
    text(x + 14, y + 22, title, size=title_size, weight="bold")
    for i, line in enumerate(lines):
        text(x + 14, y + 41 + i * 17, line, size=12, color=MUTED)


def arrow(points, label=None, lx=None, ly=None, dash=None, color=ARROW, num=None, anchor="start"):
    pts = " ".join(f"{x},{y}" for x, y in points)
    d = f' stroke-dasharray="{dash}"' if dash else ""
    out.append(f'<polyline points="{pts}" fill="none" stroke="{color}" stroke-width="2"{d} marker-end="url(#arr)"/>')
    if label:
        tx = lx if lx is not None else (points[0][0] + points[-1][0]) / 2
        ty = ly if ly is not None else (points[0][1] + points[-1][1]) / 2 - 8
        if num:
            badge(tx - 14 if anchor == "start" else tx + 14, ty - 4, num)
            tx = tx + 2 if anchor == "start" else tx
        text(tx + (6 if anchor == "start" and num else 0), ty, label, size=12, weight="bold", color=color, anchor=anchor)


def badge(cx, cy, n):
    out.append(f'<circle cx="{cx}" cy="{cy}" r="10" fill="{ACCENT}"/>')
    text(cx, cy + 4, str(n), size=12, weight="bold", color="#ffffff", anchor="middle")


out.append(
    f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
    f'font-family="DejaVu Sans, Helvetica, Arial, sans-serif">'
)
out.append(
    '<defs><marker id="arr" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
    f'<path d="M0,0 L10,5 L0,10 z" fill="{ARROW}"/></marker></defs>'
)
rect(0, 0, W, H, "#ffffff", "#ffffff", rx=0)
text(20, 34, "AI Support Agent — customer deployment architecture (AWS)", size=22, weight="bold")
text(20, 56, "Everything inside the orange boundary is owned by the customer. No component has a public IP or internet-facing listener.", size=13, color=MUTED)

# ---------------- internet / vendor
box(880, 70, 330, 50, "LLM provider API", ["api.anthropic.com:443 · public internet"], owner="vendor", fill=EXT, stroke=EXT_STROKE)

# ---------------- account + VPC
rect(250, 140, 1130, 800, ACCOUNT, ACCOUNT_STROKE, rx=14, sw=2)
text(266, 162, "Customer AWS account · us-east-1  (simulated customer environment)", size=14, weight="bold", color="#975a16")

rect(270, 180, 640, 730, VPC, VPC_STROKE, rx=12, sw=2)
text(286, 202, "Customer VPC 10.40.0.0/16 · 2 AZs · flow logs → CloudWatch", size=13, weight="bold", color=VPC_STROKE)

# IGW on top border of VPC
rect(735, 166, 120, 28, "#ffffff", VPC_STROKE, rx=6)
text(795, 185, "Internet GW", size=12, weight="bold", anchor="middle")

# public subnet strip
rect(290, 215, 600, 80, PUB, PUB_STROKE, rx=8, dash="6 4")
text(304, 236, "Public subnets 10.40.0-1.0/24", size=12, weight="bold", color=PUB_STROKE)
text(304, 254, "NAT only — nothing else is placed here,", size=12, color=MUTED)
text(304, 271, "auto-assign public IP disabled", size=12, color=MUTED)
box(680, 232, 190, 50, "NAT Gateway", ["only path to the internet"], owner="platform")

# private subnets
rect(290, 310, 600, 585, PRIV, PRIV_STROKE, rx=8, dash="6 4")
text(304, 331, "Private subnets 10.40.16.0/20 · 10.40.32.0/20", size=12, weight="bold", color=PRIV_STROKE)

box(310, 350, 180, 92, "Internal ALB", ["SG: customer CIDRs only", "HTTP 80 or HTTPS 443", "access logs → S3"], owner="platform")
box(310, 470, 180, 92, "Test client (EC2)", ["SSM Session Manager only", "no SSH key, no public IP", "IMDSv2, encrypted disk"], owner="ops")

rect(530, 345, 345, 230, "#ffffff", "#a0aec0")
out.append(f'<rect x="530" y="345" width="6" height="230" rx="3" fill="{OWN["app"]}"/>')
text(546, 367, "ECS Fargate service · 2–6 tasks", size=13, weight="bold")
text(546, 385, "CPU autoscaling · auto-rollback on failed deploy", size=12, color=MUTED)
for i, az in enumerate(("AZ a", "AZ b")):
    x = 548 + i * 162
    rect(x, 398, 150, 160, "#fffaf0", "#dd6b20")
    text(x + 10, 418, f"Agent task ({az})", size=13, weight="bold")
    for j, line in enumerate(["FastAPI + agent loop", "tools: KB search,", "  create ticket", "UID 10001, RO root FS", "all Linux caps dropped", "secrets fetched at", "  runtime (task role)"]):
        text(x + 10, 437 + j * 16, line, size=11.5, color=MUTED)

box(310, 600, 565, 92, "VPC endpoints — AWS APIs never leave the AWS network", [
    "Interface: ecr.api · ecr.dkr · logs · secretsmanager · ssm · ssmmessages · ec2messages",
    "Gateway: S3 (policy: ECR image layers only) · DynamoDB (policy: tickets table only)",
    "SG: 443 from VPC CIDR only",
], owner="platform")

box(310, 712, 565, 170, "Network controls (security-group chain)", [
    "customer CIDRs ──▶ ALB :80/443 ──▶ tasks :8080   (tasks accept traffic from ALB SG only)",
    "tasks egress: TCP 443 only (VPC endpoints + LLM API via NAT)",
    "test client: no inbound rules; egress to VPC CIDR only",
    "default security group: all rules removed",
    "no ECS Exec / SSH into containers · no internet-facing load balancer",
    "flow logs capture accepted + rejected traffic for audit",
], owner="sec")

# ---------------- AWS managed services (right column)
X = 945
WR = 415
box(X, 180, WR, 72, "AWS Secrets Manager", ["llm-api-key · client-api-key (encrypted with CMK)", "resource policy: ONLY the task role can read values"], owner="sec")
box(X, 262, WR, 52, "AWS KMS customer-managed key", ["annual auto-rotation · encrypts secrets, table, logs, SNS, images"], owner="sec")
box(X, 324, WR, 52, "DynamoDB · tickets table", ["CMK encryption · point-in-time recovery · task role: PutItem only"], owner="app")
box(X, 386, WR, 52, "Amazon ECR · agent image repository", ["immutable tags · scan on push · CMK · keeps last 30 images"], owner="app")
box(X, 448, WR, 88, "Amazon CloudWatch", ["Logs: app JSON + flow logs, 365 days, CMK", "13 log metric filters (LLM errors, latency, tokens…)", "12 alarms · dashboard · 5 saved Logs Insights queries"], owner="ops")
box(X, 546, WR, 52, "SNS alarm topic (CMK)", ["→ on-call email / pager integration"], owner="ops")
box(X, 608, WR, 52, "S3 · ALB access logs", ["SSE · public access blocked · TLS-only policy · lifecycle"], owner="sec")
box(X, 670, WR, 130, "IAM (least privilege)", [
    "execution role: pull this image, write this log group",
    "task role: read 2 secrets, PutItem on 1 table",
    "github-deploy: OIDC, one repo + protected env",
    "platform-admin · operator · auditor (MFA)",
    "nobody human can read secret values",
], owner="sec")

# private AWS network bus
out.append(f'<line x1="925" y1="216" x2="925" y2="646" stroke="{VPC_STROKE}" stroke-width="3" stroke-dasharray="2 4"/>')
for y in (216, 288, 350, 412, 492, 572, 634):
    out.append(f'<line x1="925" y1="{y}" x2="{X - 2}" y2="{y}" stroke="{VPC_STROKE}" stroke-width="2"/>')
out.append('<text x="940" y="560" font-size="11" fill="#2b6cb0" text-anchor="middle" transform="rotate(-90 940 560)">private AWS network</text>')

# ---------------- external actors (left)
box(20, 350, 205, 92, "Customer users & apps", ["corporate network / VPN", "send X-API-Key header"], owner="app", fill=EXT, stroke=EXT_STROKE)
box(20, 470, 205, 92, "Customer operators", ["SSO + MFA → operator role", "SSM port-forwarding"], owner="ops", fill=EXT, stroke=EXT_STROKE)
box(20, 640, 205, 92, "GitHub Actions (CI/CD)", ["OIDC → deploy role", "no stored AWS keys", "approval gate: 'production'"], owner="app", fill=EXT, stroke=EXT_STROKE)

# ---------------- flows
arrow([(225, 396), (310, 396)])
badge(267, 380, 1)
text(240, 416, "request", size=12, weight="bold", color=ARROW)
arrow([(490, 396), (548, 440)], "", )
text(500, 462, ":8080", size=12, weight="bold", color=ARROW)
badge(512, 480, 2)
arrow([(785, 398), (785, 282)])
badge(800, 318, 3)
text(814, 322, "LLM call", size=12, weight="bold", color=ARROW)
arrow([(795, 232), (795, 194)])
arrow([(830, 166), (930, 120)])
text(892, 160, "TLS 1.2+", size=12, weight="bold", color=ARROW)
arrow([(620, 558), (620, 600)], "AWS API calls", lx=636, ly=586, num=4)
arrow([(875, 646), (923, 646)])
arrow([(225, 516), (310, 516)])
badge(250, 500, 5)
text(264, 504, "SSM", size=12, weight="bold", color=ARROW)
arrow([(400, 470), (400, 442)])
text(408, 461, "smoke test", size=11, color=MUTED)
# CI/CD path along bottom, outside VPC
arrow([(122, 732), (122, 925), (1150, 925), (1150, 802)], dash="7 5")
badge(300, 925, 6)
text(316, 920, "release: push image to ECR, register task definition, update ECS service (AWS control plane — never through the VPC)", size=12, weight="bold", color=ARROW)

# ---------------- legend
lx, ly = 20, 90
text(lx, ly, "Ownership after hand-over", size=13, weight="bold")
legend = [
    ("platform", "Customer platform team"),
    ("ops", "Customer operations / on-call"),
    ("app", "Application team (agent)"),
    ("sec", "Customer security"),
    ("vendor", "External vendor"),
]
for i, (k, lbl) in enumerate(legend):
    out.append(f'<rect x="{lx}" y="{ly + 12 + i * 20}" width="14" height="14" rx="3" fill="{OWN[k]}"/>')
    text(lx + 22, ly + 24 + i * 20, lbl, size=12, color=MUTED)
text(lx, 228, "Numbered arrows = request & release", size=11, color=MUTED, italic=True)
text(lx, 244, "flows (see docs/architecture.md)", size=11, color=MUTED, italic=True)

out.append("</svg>")
open(sys.argv[1], "w").write("\n".join(out))
