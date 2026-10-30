# Decisions

Every choice in this repo that has a defensible alternative, why this side was
picked, and what would change the answer. If you are reading this to prepare for
a question about the project, this is the file.

## Cluster

### Kubernetes 1.35

On 2026-10-30, EKS standard support covered 1.34, 1.35, 1.36 and 1.37. The list
moves as new versions arrive, so check the
[EKS version page](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html)
before you pick one. Anything below that window falls into extended support,
where EKS bills the control plane at a much higher hourly rate, so keeping the
version current is a cost decision before it is a features one.

1.36 or 1.37 would also have been fine. 1.35 was chosen because addon and
tooling support is settled a release behind the newest, and this cluster exists
to be understood rather than to be first.

You cannot skip minor versions when upgrading, so the version you start on
determines how many hops you need later. Going back down is limited too. EKS can
roll an in-place upgrade back to the previous minor version, but only within 7
days of the upgrade.

### Upgrade policy `STANDARD`, not the `EXTENDED` default

With `EXTENDED`, a cluster whose version leaves standard support keeps running
on that version for up to another year and bills the control plane at the
extended rate. With `STANDARD`, AWS upgrades it to the next minor version at the
end of standard support.

A forced upgrade can break workloads that use removed APIs, which is the cost of
this choice. For a cluster meant to live a weekend, a surprise bill is the worse
failure. Production teams that need to hold a version while they migrate pick
`EXTENDED` on purpose and budget for it.

### Raw `aws_*` resources instead of the community EKS module

`terraform-aws-modules/eks` would replace most of `eks.tf` and `vpc.tf` with
about twenty lines. It is what most teams use and it is well maintained.

It is not used here because the point of the project is to see every IAM role,
every policy attachment, every route table association and every subnet tag. A
module that produces fifty resources you never look at teaches you nothing about
what EKS actually needs.

For a real team, use the module. Nobody should hand-roll this in production and
then maintain it.

### Public API endpoint, restricted by CIDR

`endpoint_public_access` is true, so `kubectl` works from a laptop without a
bastion or a VPN. `public_access_cidrs` defaults to `0.0.0.0/0` and should be set
to a single `/32`.

Leaving it open is not an unlocked door, because the endpoint still requires IAM
authentication. It is unnecessary exposure, which is a different and smaller
problem.

The private-only alternative means every `kubectl` goes through a bastion or VPN
inside the VPC. Correct for production, and pure friction for one person
debugging on a Saturday.

### `bootstrap_cluster_creator_admin_permissions`

Whoever runs `terraform apply` becomes cluster admin. Without it you apply
successfully and then get told you have no access, which is one of the most
common first-time EKS confusions.

The catch is that it binds to the IAM identity that applied. Apply as one
identity, run `kubectl` as another, and it fails. In a team you would add
explicit access entries for each person instead of relying on whoever ran it
first.

### Addons declared, versions not pinned

`vpc-cni`, `kube-proxy` and `coredns` run whether or not you declare them.
Declaring them puts their lifecycle in Terraform state, so upgrading is a visible
plan instead of something that drifts.

No `addon_version` is pinned deliberately. AWS then installs the default build
for the cluster version, so bumping `cluster_version` moves the addons with it.
Pinning versions is the safer production choice because you control exactly when
each moves, at the cost of having to bump them by hand.

`coredns` has an explicit `depends_on` for the node group. Install it with no
nodes and its pods sit Pending, which reports the addon as Degraded.

### IRSA, with nothing using it yet

`irsa.tf` registers the cluster's OIDC issuer as an IAM identity provider. On its
own it does nothing, because IRSA only matters once a role trusts it.

It is here because it is the answer to a question this project invites. A node
gets AWS credentials by assuming a role through its instance profile, which means
every pod on that node shares them. IRSA lets a single Kubernetes service account
assume its own role, so one pod gets S3 access and its neighbours do not.

The mechanism is worth stating precisely: the cluster signs a token, AWS verifies
that signature against the registered OIDC provider, and STS returns temporary
credentials. It works because the token is cryptographically verifiable. A pod
name or a DNS name would not work, because naming yourself is not proving who you
are.

EKS Pod Identity is the newer alternative and needs less setup.

## Network

### One NAT gateway, not one per availability zone

Both private subnets route outbound through a single NAT gateway in
`ap-south-1a`. If that AZ fails, nodes in `1b` lose outbound internet and cannot
pull images.

A NAT gateway bills hourly whether or not traffic flows, so one per AZ roughly
doubles the fixed cost of the network for a cluster that lives two days.

Production runs one per AZ. This is the single clearest place where the repo is
cheaper than it should be, which is also why `environment` defaults to `dev`
rather than claiming otherwise in the resource tags.

### Two AZs, not three

Two is the EKS minimum. Three gives better spread and costs more. Nothing here
needs quorum across three.

## Storage

### `emptyDir` everywhere, no PersistentVolumeClaims

Prometheus, Grafana and Alertmanager all write to `emptyDir`. Every metric and
every dashboard edit is lost when a pod restarts.

Persistence would need the EBS CSI driver addon, an IRSA role for it, a
StorageClass and PVCs. That is a meaningful amount of extra surface for a cluster
being destroyed on Sunday, and every one of those pieces is another thing that
can fail during a first apply.

Production attaches EBS through the CSI driver, with `ReadWriteOnce` volumes,
which is fine because each of these is a single replica.

Worth knowing the shape of the three AWS storage options, because it is a common
question. EBS is block storage, attaches to one node, behaves like a disk. EFS is
NFS, many nodes mount it at once. S3 is object storage over HTTP with no POSIX
semantics; a CSI driver can present a bucket as a filesystem, but it is still an
object store underneath and nothing that needs real file behaviour should sit on
it.

### Prometheus retention is two days

A long retention window on an `emptyDir` is a contradiction, since the data dies
with the pod. The real risk is the node's 20GB root
volume filling, which triggers DiskPressure and evicts pods, including the one
that caused it.

Two days matches how long the cluster actually lives.

### Terraform state stays local

No S3 backend. The backend block is in `providers.tf`, commented out.

A remote backend needs a bucket and a lock table that must exist before Terraform
runs, which is a chicken-and-egg problem you solve with a second Terraform project
or by clicking in the console. For one person on one laptop, that ceremony buys
nothing.

It buys a great deal for a team, where local state means no locking, no shared
view, and a cluster that becomes invisible the moment someone's laptop dies.
`terraform/terraform.tfstate` is the single most important file in this repo while
the cluster exists.

### The provider lock file is committed

`.terraform.lock.hcl` is tracked rather than ignored. It pins the exact provider
versions, so a fresh clone or a CI run resolves the same providers
this cluster was built with. Ignoring it means two machines can silently get
different AWS provider versions and produce different plans.

The AWS provider is pinned to `~> 5.0` and resolves to 5.100.0. A 6.x line exists.
Staying on 5.x is deliberate: a major provider bump can change resource schemas,
and there is no way to validate that here without an AWS account to plan against.
Bump it when you can actually run a plan.

## Monitoring

### Hand-written manifests, not `kube-prometheus-stack`

The Helm chart is what most teams run and it does far more than this, including
the operator, CRDs, ServiceMonitors and a large set of default dashboards and
rules.

It is not used here for the same reason the EKS module is not used. A chart is a
black box unless you read its templates, and the point is to understand what a
scrape config is, what RBAC Prometheus needs, and why node-exporter wants the
host's `/proc`.

Use the chart in production. Nobody should maintain this by hand at scale.

### No etcd, scheduler or controller-manager scrape jobs

This is the EKS-specific one and it is worth being able to say clearly. On a
self-managed cluster you scrape all three. On EKS, AWS runs the control plane and
does not expose those endpoints, so the jobs would fail forever.

The only control plane component reachable is the API server, through the
`kubernetes` service in the `default` namespace.

The interesting answer is not that the control plane is monitored. It is knowing
that AWS runs it, that you cannot reach it, and that CloudWatch control plane
logging is where you would look instead.

### kube-state-metrics and node-exporter are both deployed

Neither Prometheus nor the kubelet produces the series the alert rules need.
`NodeNotReady` and `PodCrashLooping` read `kube_*` from kube-state-metrics.
`HighCPUUsage` and `HighMemoryUsage` read `node_*` from node-exporter.

Leaving either one out gives you a dashboard that looks healthy while its alerts
are silently dead, which is worse than no monitoring because it produces
confidence rather than signal.

`PersistentVolumeFull` is wired correctly and still returns nothing, because there
is not a single PersistentVolumeClaim in the cluster for the kubelet to report on.
That is a missing workload, not a missing exporter.

### Why node-exporter needs host access

It runs as a DaemonSet so every node reports, and it mounts the host's `/proc`,
`/sys` and `/` read-only. Without those it would report the container's view,
which is a nearly empty namespace rather than the machine.

`hostNetwork` means the `instance` label is the node and the network metrics
describe real interfaces rather than a veth pair. `hostPID` lets process
collectors see the node's processes. `dnsPolicy: ClusterFirstWithHostNet` is
needed because `hostNetwork` otherwise inherits the node's resolver and loses
cluster DNS. It tolerates every taint, because a node you refuse to schedule
workloads on is still a node you want metrics from.

Its Service is headless on purpose. A normal ClusterIP would load balance, so each
scrape would hit one random node and the rest would go unmonitored.

### kube-state-metrics runs with a restricted collector list

Its ClusterRole grants get, list and watch on nodes, pods, namespaces,
deployments, replicasets, daemonsets and statefulsets, and nothing else.

Left at its defaults it also starts secret and configmap collectors, which have no
RBAC here and would log a permission failure on every resync forever. Passing
`--resources=` to match the ClusterRole keeps the two in step.

### Prometheus 3.x

The stack runs Prometheus 3.x, Grafana 13 and Alertmanager 0.34.

Choosing the 3.x line over the 2.53 LTS branch costs one line of config. Prometheus 3 fails a scrape outright when a
response has an unparsable Content-Type, where 2.x guessed, so the annotation-based
pod job carries `fallback_scrape_protocol`. The kubelet and API server send correct
headers and did not need it. Prometheus 3 also requires Alertmanager 0.16 or later,
which 0.34 satisfies.

### Grafana's admin password comes from a Secret

The password reads from a `grafana-admin` Secret rather than sitting as a
plaintext `value:` in the Deployment.

A Secret in a git repo is base64, not encryption, so this is a better pattern
rather than a solved problem. Sealed Secrets or the AWS Secrets Manager CSI driver
is the real fix. Note also that the Argo CD Application has `selfHeal` on, so
changing the password in-cluster gets reverted on the next sync, which is an
argument for sealing it rather than committing it.

## Operations

### `destroy.sh` deletes Kubernetes LoadBalancers before Terraform runs

This is the one that actually costs money if you get it wrong.

Kubernetes Services of type LoadBalancer create ELBs through the in-tree cloud
provider. Terraform did not create them and has no idea they exist. Run
`terraform destroy` with one still live and the VPC delete hangs on subnets the
ELB refuses to release, while the ELB keeps billing.

So the script deletes LoadBalancer services first, waits for AWS to release them,
then destroys, then sweeps for orphaned load balancers, unattached Elastic IPs and
stray EBS volumes and exits non-zero if it finds any.

Nothing in this stack currently creates a LoadBalancer, since the UIs are
reached with `port-forward`. The check is there because that will not stay true.

### `deploy.sh` makes you confirm the cost

It plans, prints what bills hourly, and requires you to type `apply`. The failure
mode for this project is not a bad apply, it is a cluster nobody destroyed.
