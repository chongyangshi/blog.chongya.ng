Title: Managed Kubernetes on a Hobbyist Budget 
Date: 2021-09-18 19:00
Category: Technical

For more than two years,  I operated a [Kubernetes cluster for my personal workloads](https://blog.scy.email/running-a-personal-kubernetes-cluster-with-calico-connected-services-on-bare-metal.html), which was self-managed across the entire stack: bare-metal dedicated servers, KVM hypervisor, `kubeadm`-bootsrapped master and worker nodes from my own `cloudinit` images, [MetalLB](https://metallb.universe.tf/) ingress, and [GlusterFS](https://www.gluster.org/) distributed storage; eventually with the cluster [spanning across data centres of multiple hosting providers over WireGuard](https://blog.scy.email/running-a-low-cost-distributed-kubernetes-cluster-on-bare-metal-with-wireguard.html).

This setup had worked very well for me throughout its lifetime, providing me with a unified interface for running personal workloads on the internet. However, keeping the cluster running was also no small feat: I have had to manually manage every level of the stack all the way down to physical servers, and if anything went down below the Kubernetes layer, recovery was also very manual.

While I am very comfortable maintaining and securing each layer of the stack by hand due to [what I do as a day job](https://scy.email/#employments), over time this exercise has become more and more wearing. Therefore I shifted my attention towards sourcing a managed Kubernetes service offering, which will continue to provide me with the flexibility of running all types of workloads as containers, but vastly reduce the time cost of maintaining it, without significantly elevating the money cost.

![Finished production metrics overview](https://i.doge.at/uploads/big/809d38f60edd94e1be1260a993d9bb12.png)

In this article, I will go through in detail the research process to find the best managed Kubernetes offering for my requirements, the designs which shave as much off the infrastructure bill as possible, and the final product as a [terraformed infrastructure on GCP](https://github.com/chongyangshi/budget-k8s), which is open-source.

_This blog post contains some opinions on various popular hosting and network service providers. As for all other posts on my blog, opinions expressed are exclusively my own._

# Selection principles

For a managed Kubernetes service offering to be suitable for moving my personal infrastructure over, the Platform-as-a-Service (PaaS) provider would need to meet the following requirements:

* **Cost**: Total running cost of the infrastructure must be reasonable for a personal project on a hobbyist monthly budget.
*  **Security**: The cluster should work over private networking, and network access to the cluster control plane and worker nodes must not be open by default. This is irrespective of any application-level access controls.
*  **Reliability**: Very occasional periods of unavailabilities can be tolerated if this significantly reduces regular running cost.
*  **Reproducibility**: It should be possible to [terraform](https://www.terraform.io/) the full infrastructure managed by the PaaS provider, and thus making recreating the infrastructure much easier in the event of an accident or provider breakdown.

I will now discuss each factor in more detail below:

### Cost

Commercial PaaS providers such as Amazon [AWS](https://aws.amazon.com/) and Google [GCP](https://cloud.google.com/) sell to organisations with a commercial cash flow; and their pricing practices reflect this: anyone working in the platform engineering type of jobs will have the experience of casually spinning up VM instances costing more than their monthly salary, since these costs ultimately facilitate commercial revenue for the organisation.

However, this model translates very poorly into the perspective of infrastructrue for personal projects, even when these personal projects only need a tiny fraction of the resources a typical commercial PaaS infrastructure requires to run.  As an example, the AWS Elastic Kubernetes Service (EKS) [charges $0.1 an hour for the managed Kubernetes control plane](https://aws.amazon.com/eks/pricing/) before any worker nodes are added. This translates to $72 a month before taxes, which would have been a tiny fraction of a typical company's PaaS infrastructure bill; but would be completely unreasonable for a personal budget financed out of our own pockets, before any workloads running on it is even considered.

In general, any managed services with high standing charges (costs incurred before any actual workload usage) will require a workaround or an alternative solution from the same provider. Once potential providers with high standing charges that are unavoidable have been discounted, we will still need to contend with high usage costs:

* CPU resources can be fairly expensive, and we need to explore any excess capacity discount options ("preemptible" or "spot" instances) available, measuredly trading off reliability for cost reductions. Some providers also offer shared-CPU options, but since Kubernetes will treat all logical CPU resources as allocatable, running the cluster on shared cores often leads to aggressive throttling or heavy CPU steals from the hypervisor. Therefore using shared cores while offering a substantial discount could have a profound negative impact on reliability.
* Egress traffic costs can be very expensive, since it is often a significant source of revenue for major PaaS providers; and for a personal project, billing alerts should be set up to detect a run-away billing scenario before it becomes disastrously expensive. 
* Data transfer cost is often charged for traffic between internal network resources, if they are located in different availability zones, or between different managed services. We need to avoid incurring these in our infrastructure design as much as possible.

It also goes without saying that Kubernetes is almost never the most cost-effective option for running personal workloads at a small scale, or even for workloads that are already containerised (think AWS Fargate). Personally I will always need a live Kubernetes cluster to test some Kubernetes-related personal projects on, and thus a reasonably-priced cluster can always fit in my hobby budget. To simply run containerised or non-containerised workloads, there are far cheaper options on the internet.

For the remainder of this article, I will base cost calculations around PaaS resources actually consumed by the workloads in my previous self-managed cluster setup, which is just under **8 vCPUs (hardware threads) and 16GB of RAM**.

### Security

There are two classes of components in a managed Kubernetes cluster:

* The cluster **control plane**, sometimes called the master nodes, which generally runs in a virtual network that is fully managed, and not under our direct control. The Kubernetes API endpoint of the control plane however has to be exposed to the user in some way to allow the cluster to be managed, and how this is implemented by different providers has significant security implications.
* The **worker nodes**, which are virtual machines that are generally under the user's direct control, albeit normally assisted by the provider's automatic provisioning and scaling features. They run workloads according to instructions from the cluster control plane's API endpoint.

Most commercial users find exposing the Kubernetes control plane on the internet unacceptable for production use, for both practical security and compliance reasons. There has been [a constant stream of vulnerabilities](https://cve.mitre.org/cgi-bin/cvekey.cgi?keyword=kubernetes) affecting master nodes and the control plane endpoint, and it is not wise to expect the managed Kubernetes provider to be able to patch the control plane before your cluster is impacted by a critical zero-day vulnerability. After all, with botnet-controlled scanners keeping a tight watch on publicly-accessible Kubernetes control planes exposed on TCP 443 all over the internet, attackers can always exploit a critical vulnerability faster than you can patch them. 

Depending on the provider, the worker nodes either talk to a private cluster control plane endpoint using their private IPs within a "Virtual Private Cloud" (VPC) network; or to a publicly-accessible control plane endpoint, after travelling a short distance over the internet using public IP addresses assigned to each worker node. Some providers implement both options and the choice belongs to us, but the default is often the less-secured public network option.

Within the design of Kubernetes, it is completely unnecessary for the control plane and the worker nodes in a Kubernetes cluster to communicate over the internet, and running Kubernetes worker nodes with any public IP address assigned at all remains a poor security design even with PKI-based authentication and encryption: in addition to workloads on all worker nodes generating egress traffic from arbitrary IP addresses, provisioning worker nodes with a public IP often causes them to become a hard dependency for the control plane endpoint to remain publicly-accessible.

Furthermore, with worker nodes having public IPs, any `NodePort` or `LoadBalancer` Service definitions will automatically expose a backend application on the internet, unless prevented by a firewall rule, which is often not enabled by default. Even where it is enabled by default, usability designs often trump security concerns. For example, in DigitalOcean's offering, the instance firewall will [automatically open any port](https://docs.digitalocean.com/products/kubernetes/resources/managed/#worker-node-firewalls) that is allocated to a `NodePort` Service, unless explicitly opted out by the user using an annotation on the Service. It is not a great argument that when a user creates a `NodePort` Service, they intend for the Service to be publicly accessible from anyone on the internet. The opposite often happens unintentionally, such as when applying Helm charts with poor defaults, and can lead to the user accidentally exposing unsecured workloads to the internet which were intended to be internal-facing.

All things considered, I would only choose managed Kubernetes offerings where there is an option for the control plane to be accessible only over the private VPC network and specifically authorized public IP ranges (such as personal VPN ranges or a home IP). Additionally, the Container Network Interface (CNI) needs to support enforcing [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/) or a CNI-specific equivalent, in order to provide additional isolation for traffic within the cluster network.

Beyond network access controls as the primary concern, many providers also offer other security features, such as managed encryption for [Kubernetes Secrets](https://kubernetes.io/docs/concepts/configuration/secret/) stored at rest and virtual machine disks (both minor concerns given the hops through which an attacker needs to jump to access the raw data); traffic logging and access auditing; RBAC access integration; and system integrity protection. They are not essential features for personal workloads, and the principle in deciding whether to enable these features largely depends on their costs versus benefits. For example, flow logs and audit logs are generally very pricy; and if my personal cluster without other people's data is hacked, being able to know who did it and what was taken would likely not be worth the storage and processing fees for maintaining such logs.

### Reliability

For personal workloads which have no strict uptime or reliability requirements, a managed Kubernetes cluster hosting them requires fewer guarantees than provided by the high-availability options of many PaaS providers.

Some providers divide regions into multiple availability zones (AZs) powered by separate physical data centres, which is an essential feature for businesses requiring uptime guarantees during rare disaster scenarios which can affect entire data centres -- even a major hosting provider with significant resources can have a [data centre catch fire once in a while](https://www.reuters.com/article/us-france-ovh-fire-idUSKBN2B20NU).  

For personal workloads however, I would rather host all resources in a single AZ and accept the risk: dozens of gigabytes of traffic are generated each month [simply by the Kubernetes control plane talking with its worker nodes](https://kubernetes.io/docs/concepts/architecture/control-plane-node-communication/), and most providers whose managed Kubernetes offering can run over multiple AZ also charge for every gigabyte of traffic sent _between_ these AZs. Additionally, in GCP's case, Google Kubernetes Engine only [waives the cluster control plane fee](https://cloud.google.com/free/docs/gcp-free-tier/#kubernetes-engine) when the managed cluster control plane runs over a single AZ ("Zonal"). Thankfully, the blast radius when distributing workloads and data in a single AZ is already significantly better than hosting all application and data on a single self-managed server.

Another trade-off between reliability and cost is related to the managed load balancers available from each PaaS provider, which are often directly integrated with a custom ingress controller in the managed Kubernetes control plane. These integrations automatically create load balancers based on `Service` or `Ingress` specifications configured by us in Kubernetes. The resulting managed load balancers are generally designed to be automatically scalable for processing and forwarding hundreds or thousands of requests per second, which is way over-kill for personal projects. 

Each managed load balancer tends to cost tens of dollars a month just on the standing charges, which becomes a significant cost barrier for personal workloads, for which different projects sharing the same cluster tend to require separate internet-facing endpoints. In the old integration model, each endpoint would require a separate load balancer, but for HTTP/HTTPS ingress, many providers are now offering custom controllers which can route ingress traffic for different backend services over the same Layer 7 load balancer. For example the [AWS Load Balancer Controller](https://aws.amazon.com/about-aws/whats-new/2020/10/introducing-aws-load-balancer-controller/) for their Elastic Kubernetes Service (EKS). However, even if all our ingress workloads are HTTP/HTTPS-based and can therefore share a single Layer 7 load balancer, it will still cost at least [$25 a month on AWS](https://aws.amazon.com/elasticloadbalancing/pricing/) and [at least $20 on GCP](https://cloud.google.com/vpc/network-pricing#lb); not to mention data processing fees charged per gigabyte, which turns free ingress traffic into billable usage.

Instead, if the cost of running managed load balancers provided by the PaaS provider will become a significant part of our monthly bill, we will have to run our own ingress instance using a low-cost virtual machine with a static public IP attached. This instance will then be responsible for routing all traffic to applications intended to be exposed to the internet, via the internal network through a `NodePort`, or for some providers via Pod IPs with VPC-native networking.

### Reproducibility

As discussed in the previous section, we will trade off some high-availability features in our design to reduce its running cost. If a disaster does happen, either due to circumstances beyond our control (such as fire or blood) or due to our accidental mishap, we don't want to have to spend a huge amount of time re-building the infrastructure.

Thankfully, most PaaS providers with managed Kubernetes offerings also have a [Terraform Provider](https://www.terraform.io/docs/language/providers/index.html) available either maintained by themselves or Hashicorp. This allows us to define the infrastructure for personal projects as code, which makes its configurations more reusable and allows us to quickly spin all the PaaS components back up if we ever lose it.

# Choosing a platform

With the above principles in mind, I set out to study the pricing model and available features for each of the popular PaaS providers with a managed Kubernetes offering:

* AWS [Elastic Kubernetes Service](https://aws.amazon.com/eks) (EKS)
* GCP [Google Kubernetes Engine](https://cloud.google.com/kubernetes-engine) (GKE)
* Microsoft [Azure Kubernetes Service](https://azure.microsoft.com/en-gb/services/kubernetes-service/)
* Linode [Kubernetes Engine](https://www.linode.com/products/kubernetes/) (LKE)
* DigitalOcean [Managed Kubernetes](https://www.digitalocean.com/products/kubernetes/)
* OVHcloud [Managed Kubernetes Service](https://www.ovhcloud.com/en-gb/public-cloud/kubernetes/) (OVH)

### AWS EKS

The managed Kubernetes offering from AWS can be populated with [EC2 Spot Instances](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html) to bring dedicated CPU cores down to an affordable price for a small cluster on a personal budget, with preemptions relatively rare; but this is pretty much the only thing associated with AWS EKS that can be managed on a personal budget.

While traffic within the same availability zone are free, it is mandatory to run EKS over two availability zones, thus a decent amount of cross-AZ traffic cost is generated just from the cluster's internal background traffic. In terms of standing charges, the cluster management fee is not waivable at $72 a month, in addition to the standing cost of a NAT Gateway instance at $36 per availability zone if we want to avoid public networking for worker nodes. 

Due to the high standing charges which is unique among our options, **it is infeasible to run an AWS EKS cluster on a personal budget.**

This is quite a shame, as AWS has implemented cluster security fairly robustly: the cluster control plane can be configured to only use private network to talk to worker nodes, and the control plane supports IP restrictions when made accessible from the internet. Managed encryption via AWS KMS is supported for Kubernetes Secrets and disks at a relatively low cost; and RBAC integration with IAM is built-in. Logging is optional at additional cost via AWS CloudWatch Logs.

### GCP GKE

As the original author of Kubernetes, Google have put a fair amount of effort into building a managed Kubernetes product that is mature in its core features. The pricing model of GCP is also more accessible to a personal budget than that of AWS:

* [Preemptible VM Instances](https://cloud.google.com/compute/docs/instances/preemptible) making dedicated CPU resources relatively affordable with rare preemptions.
* Cluster management fee is [waived on one single-AZ cluster per account](https://cloud.google.com/free/docs/gcp-free-tier/#kubernetes-engine); before mid-2020 this was free for all clusters types. In any case we want to avoid any cross-AZ traffic cost, so we only want to use a single-AZ cluster anyway.
* Low standing charge for NAT Gateways, at the cost of only a few dollars a month for a gateway handling little traffic.
* There does not seem to be a noticeable cost in the cluster's integrated logging with StackDriver.
* GCP participates in Cloudflare's ["Bandwidth Alliance"](https://www.cloudflare.com/bandwidth-alliance/), and offers a [discount on egress traffic fronted by Cloudflare](https://cloud.google.com/network-connectivity/docs/cdn-interconnect) and some other CDNs. For traffic exiting EU regions this is down from anywhere between $0.085 and $0.12 per GB to $0.05 per GB. This is still very pricy, but for personal budgets, any reduction in egress pricing is helpful.
* Managed encryption via GCP KMS is available for Kubernetes Secrets and disks, at the cost of a handful of dollars a month in a small cluster. 

One area where GCP's standing cost is higher than desired for a personal budget is the managed load balancers. The standing charge for up to five endpoint hostnames sharing a Layer 7 load balancer is around $20 a month, which is very expensive for the little traffic it will process. And additional costs are payable if you need separate Layer 4 load balancers or need to terminate more than five endpoint hostnames for your personal projects. To make it cheaper at the cost of reliability, we will need to configure and run a self-managed ingress load-balancing instance to forward traffic to the cluster.

GCP implements robust cluster security features: the control plane and the worker nodes can talk over the private network; and while control plane access is not yet integrated with their Identity-Aware Proxy, source IP restrictions can be applied to accessing the control plane from the internet. Worker node system integrity protection and secure boot are available via [Shielded Nodes](https://cloud.google.com/kubernetes-engine/docs/how-to/shielded-gke-nodes) for free. [Container sandboxing via gVisor](https://github.com/google/gvisor) is also available for free, but it will disable hardware hyper-threading to mitigate related hardware vulnerabilities, hence reducing allocatable computing resources by half. Other advanced security features at additional costs include binary authorisation and memory encryption ("Confidential Workers").

### Azure AKS

Microsoft's managed Kubernetes offering supports node pools with [spot instances](https://docs.microsoft.com/en-us/azure/aks/spot-node-pool), which brings the price of preemptible dedicated CPU instances to a comparable level with AWS and GCP. However, in Azure AKS the spot instance pool cannot serve as the default instance pool for the cluster, despite the fact that whether workloads can actually be scheduled on available worker nodes has no bearing on the control plane's health.

Therefore at least one permanent instance must be scheduled if using AKS, and we have the option of either running an expensive persistent worker node instance with dedicated CPU resources, or using a cheaper, smaller worker node shape which basically cannot run any workloads.

In terms of other standing charges, five endpoint hostnames sharing a Layer 7 load balancer is around $20 a month just like GCP. But Azure also has high standing charges for NAT Gateways: starting at $32 a month. 

While AKS does offer decent security options such as [private network clusters](https://docs.microsoft.com/en-us/azure/aks/private-clusters) and [control plane network access restrictions](https://docs.microsoft.com/en-us/security/benchmark/azure/baselines/aks-security-baseline?context=/azure/aks/context/aks-context), high standing charges from the default worker node pool and the NAT Gateway means **it is infeasible to run an Azure AKS cluster on a personal budget.**

### Linode LKS

Linode is one of the oldest providers of virtual private servers (VPS's), pre-dating the PaaS market; and their all-inclusive pricing model has been well-liked by personal users and small business customers. While Linode have since stepped into a more PaaS-style product strategy to compete with more recent entrants into the market, their managed Kubernetes offering continues with their pricing-focused selling strategy by including [a very generous egress traffic allowance](https://www.linode.com/pricing) for each worker node instance launched in the cluster. They also charge no cluster management fee.

Linode charges $20 a month for each instance of 2 vCPUs and 4GB of RAM if using shared CPU cores, or $30 if using dedicated CPU cores. Unlike the aforementioned AWS, GCP, and Azure options, these prices are for persistent instances, which removes the potential downtimes we could suffer occasionally if using preemptible VMs from one of the major PaaS providers. Additionally, reasonable sizes of instance boot disks are included in the price.

Their load balancers (called "NodeBalancers" with Kubernetes controller integration) each costs a fixed monthly price of $10, but [does not support Layer 7 connection sharing](https://www.linode.com/docs/guides/getting-started-with-load-balancing-on-a-lke-cluster/). It is however possible to run one load balancer on Layer 4 mode fronting a Layer 7 reverse proxy like [Nginx](https://docs.nginx.com/nginx/admin-guide/web-server/reverse-proxy/) or [Traefik Proxy](https://traefik.io/traefik/), which will also terminate TLS.

The main drawback of using Linode's managed kubernetes offering is network security: as far as I can tell there is currently no way to apply a source IP restriction on the control plane endpoint exposed on the internet. On the worker node side, keeping inter-node private IP communications fully private also requires [configuring a firewall feature that is not enabled by default](https://www.linode.com/community/questions/11484/top-tip-the-linode-private-networkip-is-not-private-at-all) (albeit fairly easy to configure and turn on). On balance of these factors, I'm not happy with the security model of Linode LKS.

### DigitalOcean Managed Kubernetes

Having scaled up dramatically over the past few years with lots of venture capital funding, DigitalOcean is now the main competitor to Linode in the personal and small business VPS market. Like Linode, they too offer a managed Kubernetes service with a similar pricing model:

* Free cluster management.
* 2 vCPUs and 4 GB of RAM cost $20-$24 on shared cores, or $40 on dedicated CPU cores. Boot disk storage is included.
* No preemptible or "spot" instances available.
* A generous free egress allowance per worker node instance that is similar to Linode.
* A "small" load balancer costs around $10 a month, which can front a Layer 7 reverse proxy like Nginx or Traefik Proxy running in the cluster.

On pure pricing terms, DigitalOcean is slightly more expensive than Linode for both shared and dedicated CPU options, but their pricing models are otherwise highly comparable, which is to be expected given their state of competition. 

DigitalOcean unfortunately seems to carry the same security design as Linode for the control plane endpoint exposed on the internet: there is no way to apply a source IP restriction for the public endpoint. Their worker node firewall model is better automated than Linode, but as mentioned earlier would be ideal not to [automatically open any port](https://docs.digitalocean.com/products/kubernetes/resources/managed/#worker-node-firewalls) of a `NodePort` or `LoadBalancer` Service by default. On balance of all these factors, I'm also not happy with DigitalOcean's security model.

### OVHcloud Managed Kubernetes

OVH is among a number of French and German providers traditionally providing low-cost virtual private servers and dedicated servers. Many of these providers have pivoted into PaaS-style offerings, with OVH branding theirs as "OVHcloud", and they have also been quick to build a managed Kubernetes offering. Their pricing model is somewhat similar to Linode and DigitalOcean:

* Free cluster management.
* 2 vCPUs and 7 GB of RAM (minimum) costs around $29.2 on dedicated cores, or 2 vCPUs and 4GB of RAM of their "Discovery" instances with shared cores for around $12.5. Boot disks are included in the price.
* No preemptible or "spot" instances available.
* Egress is completely free in most regions at a bandwidth sufficient for hosting personal projects.
* An load balancer costs around $16 a month, which can front a Layer 7 reverse proxy like Nginx or Traefik Proxy running in the cluster.

Prices for dedicated cores on OVH (even the non-computing-optimised ones) is slightly cheaper than Linode and somewhat more so than DigitalOcean, but still broadly similar. On the security front, OVH supports private IPs for nodes, but according to their control plane, even with private IPs enabled "the public IPs of these nodes will be used exclusively for administration/linking to the Kubernetes control plane", and Pod networking appears to use the deprecated [Gravational wormhole](https://github.com/gravitational/wormhole). Source IP restriction is however available on the internet-facing control plane endpoint. This is the important security feature which Linode and DigitalOcean have not implemented.

### The choice

After turning over the pricing and security models of six providers with managed Kubernetes offerings, two viable candidates have emerged: GCP GKE and OVHcloud Managed Kubernetes. 

To achieve the level of computing resources required (8 vCPUs and 16GB of RAM) in London (or as close to London as possible), using preemptible instances on GCP works out to be a little more expensive than using persistent instances with shared-CPU resources on OVH, depending on the user's sales tax status. The price difference primarily accounts for storage and egress traffic costs, both of which are free on OVH and are a few dollars extra on GCP. Because OVH instances are persistent, they theoretically offer better reliability guarantees than preemptible instances on GCP, but the OVH option will also involve shared-CPU instances with variable performance.

Their managed load balancers are similarly priced, and the option to use a small, self-managed persistent instance as ingress proxy works out to be cheaper than a managed load balancer on both platforms. For a personal project, both platforms check the same security boxes I need: private network clusters and control plane network access restrictions. GCP offers better integrated managed encryption and logging solutions, but these are of little consequence in this use-case.

| Managed Kubernetes Provider                         | GCP GKE (London)       | OVH                       | Linode LKE                | DigitalOcean |
| --------------------------------------------------- | ---------------------- | ------------------------  | ------------------------- | ------------ |
| Estimated total monthly cost* with persistent^ VMs  | $266                   | $130                      | $137                      | $180                      |
| Estimated total monthly cost* with preemptible^ VMs | $83`                   | N/A                       |  N/A                      | N/A                       |
| Estimated total monthly cost* with shared-CPU VMs   | N/A+                   | $62                       |  $97                      | $100                      |
| Meets my security requirements                      | Yes                    | Partially                 |  No                       | No                        |
| Cluster over multiple AZs in the same region        | Supported but not used | Likely single-DC | Likely single-DC        | Likely single-DC |
| Reproducible infrastructure with Terraform          | Yes (by Hashicorp)     | Yes (provider-maintained) | Yes (provider-maintained) | Yes (provider-maintained) |

_Footnotes_:

* *: _including any separately-billed costs for storage and realistic egress usage_
* ^: _only vitual machines which has access to dedicated CPU resources when running, shared-CPU options listed separately_
* `: _using a custom shape of 2/4 vCPUs + 4/8 GB of RAM on N2D instance type_
* +: _GCP offers shared-core VMs but will reduce the amount of allocatable CPUs by half, and therefore impractical to use_

After considering both options, **I decided to go with GCP GKE** despite the potential reliability concerns in using preemptible instances. This is because the minimal reliability requirements of personal workloads would allow me to take advantage of some cost savings, even with realistic storage and egress traffic consumptions considered. OVH provides better value if using the shared CPU option, but their control plane features look somewhat less mature, and private networking is not fully supported within the cluster, with the deprecated [wormhole](https://github.com/gravitational/wormhole) as the overlay network with a ["canal"](https://docs.projectcalico.org/getting-started/kubernetes/flannel/flannel) (Calico & Flannel) setup.

If Google decides to change their pricing model in the future and no longer waive cluster management fees on a single-AZ cluster, or starts to actually preempt my instances more often, there is always the option to move to OVH (or Linode / DigitalOcean if they opt to implement better network security).

# Infrastructure Design

With cost reduction, security, and reliability prioritised accordingly, I arrived at a design as shown in the diagram below:

![final GCP infrastructure design](https://i.doge.at/uploads/big/ba2364096616174794f0e1be4d1b9e18.png)

### Network and cluster layouts

The GKE Kubernetes control plane runs in a GCP-managed VPC within a single AZ, which is connected to the primary cluster subnet with [all of its worker nodes](https://github.com/chongyangshi/budget-k8s/tree/main/terraform/base) in the same AZ via an automatic peering connection. They communicate through private VPC networking. This setup both waives the cluster management fee on GCP and ensures that we pay no cross-AZ data cost, as the control plane and worker nodes are in the same AZ at all times. In the rare event an entire AZ does go down, everything will be unavailable temporarily. This mode of failure is similar to managed Kubernetes providers whose PaaS platfroms run in single-data-centre regions.

Worker nodes are distributed between two worker pools, running two of `n2d-custom-2-4096` preemptible instances (2 vCPUs and 4GB RAM) and one of `n2d-custom-4-8192` (4 vCPUs and 8GB RAM) preemptible instance respectively to meet my resource consumption and shape requirements. By distributing preemptible instances across two node pools, we attempt to reduce the likelihood of simutaneous preemptive terminations somewhat.

[Pods](https://kubernetes.io/docs/concepts/workloads/pods/) form the lowest-level network primitive within Kubernetes, and they are allocated [VPC-native](https://cloud.google.com/kubernetes-engine/docs/concepts/alias-ips) IP addresses from a secondary IP range of the cluster subnet by the Container Network Interface (CNI) integrated in GKE. `ClusterIP` [Services](https://kubernetes.io/docs/concepts/services-networking/service/) routed by `kube-proxy` are allocated native IP addresses in another secondary IP range of the same subnet. This setup means that Pod IPs selected by Services in the cluster can be reached from anywhere in the VPC directly -- even from outside the worker nodes, as long as the VPC firewall rules and Kubernetes [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/) allow such traffic.

As no VM instance or Kubernetes Pod in the cluster network has a public IP for reasons of good security practice, they cannot originate traffic to the internet -- such as to pull Docker images from a public registry. Instead, we need a [managed NAT Gateway](https://cloud.google.com/nat/docs/overview) for the VPC, which conveniently only costs a few dollars on GCP including the standing charge and the anticipated low volume of egress traffic. It appears that the static IP assigned to the NAT gateway does not incur any costs, and it makes the egress IP from the cluster predictable for authorising access elsewhere.


### HTTP/HTTPS ingress

Due to the high standing charge of a managed load balancer on GCP, my design makes no use of the native load balancing integration in GKE. Instead, we place a [Traefik Proxy](https://doc.traefik.io/traefik/) ingress controller _outside_ the cluster and in a self-managed, persistent Google Compute Engine instance, using an economical shape of `e2-micro`. This takes advantage of the following facts:

* [VPC-native](https://cloud.google.com/kubernetes-engine/docs/concepts/alias-ips) cluster networking means that a non-Kubernetes VM which has both a public IP reachable from the internet and a private IP, can forward traffic to Pod IPs of front-end services running in the cluster (without going through a NodePort), as long as such traffic is allowed under VPC firewall rules.
* The GKE control plane exposes a private network interface in the designated master node range (by default `172.16.0.2`), and this is also reachable from anywhere in the VPC as long as [the control plane's authorized networks list includes the source private IP range](https://cloud.google.com/kubernetes-engine/docs/concepts/private-cluster-concept#overview). This allows us to run ingress [controllers](https://kubernetes.io/docs/concepts/architecture/controller/) outside the cluster, as long as they hold [`ServiceAccount`](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/) credentials issued from within the cluster with appropriate permissions.
* We can reserve a [static public IP address](https://cloud.google.com/compute/docs/ip-addresses/reserve-static-external-ip-address) from GCP for a few dollars a month, and reassign it to the new instance after we destroy an old one. The ingress instance can hence keep the same IP even if we need to recreate it from time to time, removing any need for a dynamic DNS service.
* We can produce a (mostly) reproducible operating system setup for the ingress instance by specifying a fixed image "generation" and a [start-up script](https://cloud.google.com/compute/docs/instances/startup-scripts/linux).

Based on some existing works by others (linked in code), I created a [systemd setup](https://github.com/chongyangshi/budget-k8s/tree/main/terraform/ingress/instance_resources) for running the Traefik Proxy binary in the persistent ingress instance outside the GKE cluster. The setup process is [scripted](https://github.com/chongyangshi/budget-k8s/blob/main/terraform/ingress/instance_resources/bootstrap.sh) to make it as reproducible as possible via Terraform, and replacing the instance is as simple as re-applying Terraform. An [instance group](https://cloud.google.com/compute/docs/instance-groups) with a launch configuration is not used, as there is no easy way to assign a single static IP to instances managed by an instance group (we are supposed to use a managed load balancer to achieve that, which defeats the purpose of saving cost).

Configurations through the [Terraform Kubernetes Provider](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs) will automatically load minimally-privileged credentials from the managed cluster into the ingress instance for use by the Traefik Proxy runtime. Traefik Proxy will then continuously watch the cluster control plane via the private VPC network for `Ingress` objects created in its designated `IngressClass`, and set up hostname-based traffic forwarding paths accordingly for all front-end applications intended to be accessible from the internet.

For each front-end application, its intended external-facing hostnames are registered with Traefik using the `hostname`s specified in their `Ingress` rules. Using the standard router configuration, Traefik will then terminate and forward TLS traffic intended for hostnames registered to each `Ingress`, by automatically issuing [Let's Encrypt ACME](https://letsencrypt.org/how-it-works/) certificates. These certificates are trusted by most clients (even though it is better to also put a CDN with TLS support in front of the endpoints for cost and security reasons), and their issuances are validated by [Traefik automatically redirecting HTTP challenge requests to an endpoint it manages internally](https://doc.traefik.io/traefik/https/acme/0).

![Using a generated service proxy to avoid exposing sensitive backend Kubernetes Secrets to Traefik due to controller namespace access requirements](https://i.doge.at/uploads/big/386c9e5d976d9aad92b2524320d2f725.png)

Due to some [stubborn design limitations of Traefik Proxy's controller](https://github.com/traefik/traefik/issues/7097) with regarding to storing and accessing existing TLS secrets backed by Kubernetes secrets, all namespaces where `Ingress` objects are watched by Traefik must allow Traefik's `ServiceAccount` to read all Kubernetes Secrets within them, even if Traefik has no business in doing so (for example, when it already provisions TLS certificates using ACME internally). Since Kubernetes Pods can only mount Secrets within their own namespace, and in our setup Traefik runs in an internet-facing instance outside the cluster, this constraint significantly weakens the security of any Kubernetes Secrets intended for use by backend services if they run in the same `ingress` namespace.

It is possible to target a Kubernetes `Service` at an arbitrary hostname using the service type [`ExternalName`](https://kubernetes.io/docs/concepts/services-networking/service/#externalname). One might attempt to target an internal `Service` hostname such as `secret-api.another-namespace.svc.cluster.local` using an `ExternalName` service in the `ingress` namespace, and exposing that to Traefik. However, due to how Kubernetes networking works, Services cannot be reached from outside the cluster through VPC networking -- they are, after all, just `kube-proxy` iptables forwarding rules on Kubernetes nodes. 

To solve this, I implemented a light-weight service proxy for forwarding traffic from Traefik to sensitive backend services inside other namespaces in the cluster, by [generating NGINX deployments as a Layer 4 proxy](https://github.com/chongyangshi/budget-k8s/tree/main/terraform/ingress/service_proxy) each targeting a specific backend service. This service proxy is abstracted through an [easy-to-use module](https://github.com/chongyangshi/budget-k8s/blob/main/terraform/ingress/gke_ingresses.tf.example), which only provisions a service proxy (instead of having Traefik target front-end service Pods directly) if the target namespace differs from the front-end `ingress` namespace. 

### Managing the cluster

As configured, the cluster on GCP has both a public and a private endpoints for the control plane. [Access to both endpoints](https://cloud.google.com/kubernetes-engine/docs/concepts/private-cluster-concept#overview) are controlled by the "authorised networks" list, which firstly allows private network connections from the ingress subnet so that Traefik could reach the private endpoint to load information about `Service`s receiving ingress traffic; and secondly allows public network connections from the user's source IPs for [`kubectl`](https://kubernetes.io/docs/reference/kubectl/overview/) access.

Local `kubectl` credentials are [configured](https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl#viewing_kubeconfig) using GCP's command line client. There is [a native integration](https://cloud.google.com/kubernetes-engine/docs/how-to/iam) between the GCP IAM and the cluster RBAC, and the user's Google identity is by default already bound to the cluster admin role. Given this is a single-user cluster, further configurations of access will not be very meaningful to security.

Something I'm not particularly happy about in this access solution -- in common with other managed Kubernetes offerings which provide source IP access restrictions -- is that while the source IP of a user would be predictable if they have a static home IP address or a VPN server; this security model will be much harder to use by those relying on dynamically-allocated or NAT home IPs. And the GKE control plane can only be accessed via IPv4, therefore using IPv6 is entirely out of the question for those with IPv6 static IPs only. 

A possible solution which I've experimented with is to set up a [TCP Route](https://doc.traefik.io/traefik/routing/routers/#configuring-tcp-routers) in Traefik running on the ingress load-balancing instance, whose ingress port is only exposed to the GCP Identity-Aware Proxy, and whose backend ("service" in Traefik concepts) is configured as the GKE control plane's private IP. Through the IAP, the user can then set up [TCP-forwarding](https://cloud.google.com/iap/docs/using-tcp-forwarding) from their local command line environment in one terminal, and connect to the GKE control plane in another terminal using `kubectl` with a slightly-modified `kubeconfig` file, which has the public IP of the control plane endpoint replaced with the private one. 

However, while the connectivity is completely achievable this way, `kubectl` does need to validate the IP Subject Alternative Names (SANs) on the certificate presented by the control plane endpoint. That certificate is managed by GKE and does not include `127.0.0.1` as a permitted IP SAN. It is certainly possible to run `kubectl` with `--insecure-skip-tls-verify=true`, but I felt that at this point the degraded security practice becomes worse than just putting the control plane on the internet. Traefik can alternatively obtain a valid TLS certificate for an SNI hostname on the TCP route (which has to be DNS-validated rather than HTTP-validated given it is behind IAP), but it will then require a local DNS override to use `kubectl`, which is also very awkward to use.

Therefore, the best option going forward is to wait for GCP to implement native IAP support for private GKE control planes. In the meantime, a possible workaround is to add an [IKEv1 IPSec VPN server](https://blog.scy.email/mixed-ikev2-ikev1-cisco-ipsec-vpn-server-with-no-user-certificates.html) to the ingress instance, and open the required ports in the VPC firewall. This will allow the private control plane endpoint of the cluster to be reached via the VPN. 

### Managed services supporting the cluster

Being on GCP means we have access to a range of relatively mature managed services, which removes a lot of management overhead for resources outside the cluster at a relatively low cost. These include:

* The [Identity-Aware Proxy](https://cloud.google.com/iap/docs/using-tcp-forwarding) for SSH access and TCP forwarding to the ingress instance and worker nodes, when required. This service is currently free.
* The [NAT Gateway](https://cloud.google.com/nat/docs/overview) for the VPC enabling private cluster networking, which costs a handful of dollars a month at our scale.
* The [Key Management Service](https://cloud.google.com/security-key-management) for encrypting cluster `etcd` database and instance disks, which is a handful of dollars a month even though not strictly necessary.
* The [Container Registry](https://cloud.google.com/container-registry) for hosting private Docker images used in the cluster, backed by Google Cloud Storage and at our level of usage the monthly cost is in pennies.
* [Persistent volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/) attached to stateful workloads such as Prometheus are backed by [GCP Persistent Disks](https://cloud.google.com/compute/disks-image-pricing), as is the case for boot disks of VM instances. Altogether my provisioned volumes cost around $10 a month using the cheapest tier, which is sufficiently performant for my requirements.

# Comparison

In the final part of this article, I will look at whether the resulting solution has met the various goals set out earlier, which are summarised in the table below:

|                            | GCP GKE (new) | Self-managed (old) |
| -------------------------- | ------------- | ------------------ |
| **Hardware**               | | |
| Computing Resources        | 8 vCPUs and 16GB RAM | 12 vCPUs and 22GB RAM |
| Utilisation                | ~84%                 | ~56% |
| CPU Models                 | AMD EPYC 7742        | Intel i7-4770 (4c8t) & E3-1220v5 (4c4t)|
| Single-Core Passmark       | 2174                 | 2175 & 2006 |
| **Costs**             | | |
| Monthly Egress Usage       | 10GB                 | 50GB (Control Plane and Prometheus communicate via WireGuard over public egress |
| Monthly Egress Cost        | $0.05/GB             | >15TB flat allowance included |
| Persistent Storage         | Managed PD on HDD    | GlusterFS cluster on HDD (self-managed) |
| Storage Cost               | ~$11 ($0.048/GB/mo)  | Included in server cost |
| Total Monthly Cost         | **~$83**             | **~$57** |
| **Security**               | | |
| Private Cluster Networking | Yes                  | Yes (local and WireGuard) |
| Network Policies           | Yes (managed CNI)    | Yes (Calico) |
| Encrypted etcd             | Yes (managed)        | No (not particularly important) |
| Encrypted disks            | Yes (managed)        | No (not particularly important) |
| OS Integrity Protection    | Yes (managed)        | No (not particularly important) |
| **Reliability**            | | |
| When control plane fails   | If the AZ goes down       | If hypervisor or server hardware goes down |
| When worker nodes fail     | If the AZ goes down       | If hypervisor or server hardware goes down, or if WireGuard disconnects |
| Worker node creation       | Automatic                 | Manual |
| Worker node replacements   | Automatic                 | Manual |
| Ingress from internet      | Self-managed GCE instance | Self-managed MetalLB via a single server |
| Ingress failure recovery   | `terraform apply`         | Manual repair and recovery at hardware server level |
| **Reproducibility**        | | |
| Infrastructure as Code     | Terraform for all parts   | Not implemented, would have required Puppet or Hashicorp Packer |

At the end of this project, I have removed most of the manual work involved in maintaining the infrastructure for my personal projects using a managed PaaS solution, and replaced them with managed PaaS resources with comparable performance. This resulted in an approximately 45% increase in the monthly cost. The new infrastructure is easier to scale up in the event of unanticipated demand, and a lot easier to recreate in a disaster scenario. 

Since the monthly cost remains affordable on my hobby budget while delivering significant time savings, it is working well for me so far.  However, this infrastructure will not be scalable for hosting high-bandwidth services (such as self-hosted streaming), and should this be needed in the future, an alternative solution will be required.
