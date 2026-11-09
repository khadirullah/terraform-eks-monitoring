# Live runs

This stack has been applied to a real EKS cluster three times. Each run has a
page with what I tested, what happened and what I changed after it, and a
folder of the real terminal output.

| Run | Date | What it tested | Result |
|---|---|---|---|
| [1](run-1-2026-10-28.md) | 2026-10-28 | First apply, a crashing pod, a node with its kubelet stopped | Both alerts fired. Found three bugs and a README that promised dashboards. |
| [2](run-2-2026-10-28.md) | 2026-10-28 | The same checks after the fixes | All three fixes held. |
| [3](run-3-2026-11-09.md) | 2026-11-09 | `scripts/destroy.sh` with load balancers from other projects already in the account | Only the load balancer Kubernetes made was removed. The other three were left alone. |

All three ran in us-east-1 on two t3.small nodes, each in a throwaway sandbox
account.

## What was changed in the logs

The logs are the real output, with these changes so they are safe to publish:

- AWS account numbers are `<account-id>`.
- EKS cluster and OIDC IDs are `<cluster-id>`.
- Public IP addresses are `<public-ip>`.
- My home folder is `/home/<user>`.
- Each run of `Still creating...` or `Still destroying...` lines is one `...`
  line.
- Terminal colour codes are removed.
- Commands that were not part of the run are left out, such as taking
  screenshots for the blog post and git commits.

Run 1 also has a notes file that I wrote during the run. It has the real
output under each `$` command, plus a few lines of my own notes.

The full write-up of runs 1 and 2 is the post
[I ran my EKS monitoring stack and broke it on purpose](https://khadirullah.com/blog/terraform-eks-monitoring-live-run/).
