# Runbook

Everything you actually type, in order.

## Before the first apply

You need an AWS account with billing set up, and these four on your PATH:

```bash
terraform version    # 1.5 or later
aws --version
kubectl version --client
git --version
```

Authenticate. Use an IAM user with programmatic access, or SSO if you have it.

```bash
aws configure
aws sts get-caller-identity    # confirms who Terraform will act as
```

Whoever runs `terraform apply` becomes cluster admin, because
`bootstrap_cluster_creator_admin_permissions` is true. If you apply as one
identity and then try `kubectl` as another, you get told you have no access and
it is confusing. Same identity throughout.

## Configure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`. The one setting worth changing before you apply:

```bash
curl -s https://checkip.amazonaws.com    # your public IP
```

Put that in `public_access_cidrs` as `["x.x.x.x/32"]`. Left at the default the
Kubernetes API server endpoint is reachable from the entire internet. It is
still authenticated, so this is not an open door, but there is no reason to
present the endpoint to everyone when you are the only user.

## Apply

```bash
./scripts/deploy.sh
```

It plans, shows you what it costs, and makes you type `apply`. Expect 15 to 20
minutes, most of it waiting for the control plane.

If you would rather drive it yourself:

```bash
cd terraform
terraform init
terraform plan -out=tfplan
terraform apply tfplan
aws eks update-kubeconfig --region ap-south-1 --name eks-monitoring
kubectl apply -f ../k8s/monitoring/namespace.yaml
kubectl apply -f ../k8s/monitoring/
```

The namespace goes first on its own. kubectl applies a directory in file name
order, and `alertmanager-deployment.yaml` sorts before `namespace.yaml`.

## Verify

```bash
kubectl get nodes                       # 2 nodes, Ready
kubectl get pods -n kube-system         # coredns, kube-proxy, aws-node all Running
aws eks list-addons --cluster-name eks-monitoring --region ap-south-1
kubectl get pods -n monitoring          # prometheus, grafana, alertmanager
```

If nodes never reach Ready, the usual cause is the node group failing to reach
the control plane or the ECR endpoint. Check the NAT gateway exists and the
private route table actually points at it.

If CoreDNS sits Pending, there were no nodes when the addon installed. That is
why `coredns` has an explicit `depends_on` for the node group.

## Reach the UIs

Port-forward, one terminal each. Nothing here is exposed publicly on purpose.

```bash
kubectl port-forward -n monitoring svc/grafana      3000:3000
kubectl port-forward -n monitoring svc/prometheus   9090:9090
kubectl port-forward -n monitoring svc/alertmanager 9093:9093
```

Grafana admin password:

```bash
kubectl get secret -n monitoring grafana-admin \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

Change it from the placeholder before you apply, or seal it. Note that the Argo
CD Application has `selfHeal` on, so editing the Secret in-cluster gets reverted
on the next sync.

## Prove the monitoring works

A dashboard full of graphs is not proof. Check that Prometheus is actually
scraping and that a rule can fire.

In Prometheus at `localhost:9090`, Status then Targets. Every job should be UP.
Then run a query that only works if the exporters are alive:

```promql
up
kube_pod_status_phase
node_memory_MemAvailable_bytes
container_memory_working_set_bytes
```

An empty result for any of those means that exporter is not being scraped, and
any alert rule depending on it is dead. A rule that cannot fire is worse than no
rule, because the dashboard looks fine.

### Make the alerts fire

Scraping working is still not the same as alerting working. Break something on
purpose and watch it go through Prometheus to Alertmanager.

A crashing pod, for `PodCrashLooping`:

```bash
kubectl run crashtest --image=busybox -- sh -c "exit 1"
```

It reaches CrashLoopBackOff within a minute and the alert fires 5 minutes after
that. Check `localhost:9090/alerts`, then `localhost:9093` for the same alert
under `slack-critical`. Delete the pod when done.

A dead node, for `NodeNotReady`. Stop the kubelet on a node that is not running
Prometheus, otherwise Prometheus goes down with it:

```bash
kubectl get pods -n monitoring -o wide          # see where prometheus runs
kubectl debug node/<other-node> --profile=sysadmin --image=busybox:1.37 \
  -- nsenter -t 1 -m -u -i -n -p -- systemctl stop kubelet
```

Do not terminate the instance for this test. AWS deletes the Node object within
a minute of termination, so the series disappears before the 5 minute `for`
runs out and the alert never fires. With only the kubelet stopped, the node
goes NotReady (Ready shows `Unknown`) in under a minute and the alert fires 5
minutes later. Pods are evicted to the other node at the same 5 minute mark.

On the first run, node-exporter on the dead node stayed UP while its kubelet
and cAdvisor targets went DOWN. NotReady means the kubelet stopped reporting,
not that the machine is off.

Bring it back by rebooting the instance, which starts the kubelet again:

```bash
aws ec2 reboot-instances --region <region> --instance-ids <instance-id>
```

The node was Ready about 30 seconds after the reboot and the alert resolved
right after. Pods do not move back on their own.

## Upgrading the cluster

Order matters and you cannot skip versions or go backwards.

1. Check for removed APIs first. A control plane upgrade is what breaks
   workloads, not the node upgrade.
2. Control plane. Bump `cluster_version` in `terraform.tfvars`, one minor
   version at a time, and apply. Takes 10 to 20 minutes, and the API stays
   available.
3. Addons. `vpc-cni`, `kube-proxy` and `coredns` are declared without a pinned
   version, so AWS resolves the default for the new cluster version. Apply again
   and they move.
4. Node group last. Terraform rolls the nodes, draining and replacing them. The
   kubelet must never be far behind the API server, so nodes follow the control
   plane rather than leading it.

The reason nodes go last is that a new control plane will talk to slightly older
kubelets, but an old control plane will not talk to newer ones. Upgrade the thing
that tolerates the skew first.

## Destroy

```bash
./scripts/destroy.sh
```

Read [cost.md](cost.md) for why this is not just `terraform destroy`, and for
the billing check to run the next day.

## When it goes wrong

**`terraform apply` fails partway.** State is local in
`terraform/terraform.tfstate`. Do not delete it. Fix the error and apply again,
Terraform picks up where it stopped. Delete that file and Terraform forgets the
cluster exists while AWS keeps billing for it.

**`kubectl` cannot resolve the cluster endpoint right after apply.** The
endpoint is a brand new DNS name, and AWS publishes it a few minutes after the
cluster reports ACTIVE. If your machine asked during that gap, its resolver
cached the "no such name" answer and keeps returning it. Compare:

```bash
dig +short <endpoint-host>             # your resolver, empty while cached
dig +short @8.8.8.8 <endpoint-host>    # public resolver, returns the IPs
```

If the public resolver answers and yours does not, wait a few minutes and try
again. An `/etc/hosts` line with one of the IPs works as a stopgap, but remove
it once your resolver catches up, because those IPs can change.

**`kubectl` says Unauthorized.** You are not the identity that created the
cluster. Check with `aws sts get-caller-identity`.

**Grafana keeps restarting.** `kubectl describe pod -n monitoring -l
app.kubernetes.io/name=grafana` and read Last State. `OOMKilled` means it hit
its memory limit. `Error` with exit code 137 and "Liveness probe failed" in the
events means it was too slow to answer `/api/health` and the kubelet killed it.
Both happened at a 512Mi limit, which is why the limit is now 1Gi. A restart
also drops any `port-forward` to the old container, so start it again.

**Pods stuck Pending.** Usually not enough room on two t3.medium nodes,
especially with Argo CD also running. `kubectl describe pod` names the reason.

**Destroy hangs on the VPC.** Something outside Terraform is holding a subnet,
almost always a load balancer created by a Kubernetes Service. That is what step
one of the destroy script is for.
