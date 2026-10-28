# What this costs and how to not get surprised

This project creates billable AWS resources. Unlike every other project in this
repo family, you cannot leave it running.

Rates below are approximate for `ap-south-1` and are here for order of magnitude,
not for accounting. Check the real numbers at
<https://calculator.aws/> before you apply, because prices change and they differ
by region.

## What bills, and whether idling saves you

| Resource | Roughly | Bills when idle? |
|---|---|---|
| EKS control plane | ~$0.10 per hour, per cluster | Yes. Flat rate, no usage component. |
| NAT gateway | ~$0.05 per hour, plus per GB processed | Yes. The hourly charge runs whether or not a byte moves. |
| 2x t3.medium nodes | ~$0.04 per hour each | Yes, while running. |
| Elastic IP | Free while attached to the NAT gateway | Charged hourly if it ends up unattached. |
| EBS root volumes | 2 x 20GB gp3, a few dollars a month | Yes, and they survive if a destroy half fails. |

The thing to notice is that nothing in that table gets cheaper by being unused.
There is no scale-to-zero here. An EKS cluster doing nothing costs the same as
one under load.

## The weekend shape

Stand it up Saturday morning, destroy it Sunday night, and you are looking at
somewhere in the region of ten to twenty dollars.

Leave it running for a month by accident and it is well into three figures. That
is the only real risk in this project, and it is entirely avoidable.

## Extended support, the expensive trap

EKS charges a much higher hourly rate for the control plane once your Kubernetes
version falls out of standard support. The jump is large enough that a forgotten
cluster on an old version costs several times what you expect.

This is why `cluster_version` is pinned to a version inside the standard
support window, and why moving it forward is part of the routine rather than
something to put off.

Pinning the version is not enough on its own. AWS creates clusters with
`upgrade_policy` set to `EXTENDED` unless you say otherwise, so a cluster left
running past its version's standard support quietly moves to the extended rate.
`eks.tf` sets `support_type = "STANDARD"`, which makes AWS upgrade the control
plane to the next version instead. The first live run of this repo showed
`EXTENDED` in the destroy plan before this was set.

## Teardown

```bash
./scripts/destroy.sh
```

Not `terraform destroy` on its own. The script deletes Kubernetes Services of
type LoadBalancer first, because those create ELBs that Terraform never created
and knows nothing about. Destroy the VPC with an ELB still in it and the delete
hangs on subnets that will not release, while the ELB keeps billing.

After Terraform finishes, the script sweeps for orphaned load balancers,
unattached Elastic IPs and stray EBS volumes, and exits non-zero if it finds any.

## Check the bill anyway

An empty region today is not proof of a zero bill. Charges land late.

```bash
aws ce get-cost-and-usage \
  --time-period Start=$(date -d '7 days ago' +%Y-%m-%d),End=$(date +%Y-%m-%d) \
  --granularity DAILY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE
```

Set a billing alarm before your first apply, not after. In the Billing console,
Budgets, a monthly budget of whatever number would actually annoy you, with an
email alert at 50% and 100%. It takes two minutes and it is the difference
between noticing on day two and noticing on the statement.

## Why the design is cheap on purpose

One NAT gateway instead of one per availability zone. That is a real
availability tradeoff: if `ap-south-1a` fails, private subnets in `1b` lose
outbound internet and nodes there cannot pull images. For a cluster that lives
two days, paying twice over to survive an AZ failure is not worth it. In
production you would run one per AZ and accept the cost.

Two t3.medium nodes, not three, and no persistent volumes. Metrics live in
`emptyDir` and die with the pod, which is fine for a demo and wrong for
production, where you would attach EBS through the CSI driver.

Both of those are deliberate. See [decisions.md](decisions.md) for the rest.
