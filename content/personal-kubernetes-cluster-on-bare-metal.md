Title: Running a personal Kubernetes cluster with Calico-connected services on bare-metal 
Date: 2019-06-09 18:00
Category: Tutorial

Out of boredom, I decided to undertake an infrastructural experiment of setting up a personal [Kubernetes](https://kubernetes.io) cluster, and moving as much of my personal project workloads into the cluster as possible. The purpose of this exercise was _not_ to improve the resiliency of these fairly inconsequential workloads, but rather to see how far I could go in stretching this setup to fit low-cost servers I acquired from some infamous European providers. 

![Architecture of personal Kubernetes cluster](https://images.ebornet.com/uploads/big/61a580ae16a9c3463ad3066b95d31d9e.png)

It took some trial and errors over a couple weeks of time, but eventually I was able to achieve a setup that is functional and reasonably painless to maintain.

Two servers are used in the setup:

* A bare-metal Debian **host server** running QEMU-KVM (`libvirt`), which in turn runs a number Ubuntu guest VMs, each running a Kubernetes master or worker node, or a [GlusterFS]([https://www.gluster.org/](https://www.gluster.org/)) replicated storage node. 
    * The host server runs former VPS host-grade hardware, and therefore was fairly inexpensive to lease from the right provider, but yet still pretty powerful enough to run my cluster.
    * The Kubernetes node network (`10.100.0.0/25`) is segregated from the public internet.
    * Two IP addresses are used, one for the exclusive use of ingress to web services running in Kubernetes (`10.100.0.128/25`), and another for host maintenance and protected `kubectl` access.
    * Ubuntu guest images were built with [Cloud-Init](https://cloudinit.readthedocs.io/en/latest/) and runs in DHCP mode.

* An **auxiliary server**, a low-cost yet fairly powerful virtual machine hosted with a different provider.
    * It was originally intended to be set up as an off-site Kubernetes worker node connected into the main cluster via WireGuard. While I managed to get kubelet joining the master node successfully and its [Calico](https://www.projectcalico.org/) node reaching the main cluster network, I ran into some weird issues with [send/receive offloading](https://en.wikipedia.org/wiki/Large_send_offload) causing longer-than-MTU pod traffic packets to be dropped on Calico over WireGuard, and had to abandon this idea.
    * If you know why this happens, and how to fix it, please do [get in touch](mailto:hello@scy.email) -- I'm intrigued.
    * The auxiliary server runs workloads which are tricky to containerise, including my private Docker build environment and container repository (major `iptables` screw-up) and MySQL for backing some legacy projects. 

* [WireGuard]([https://www.wireguard.com/](https://www.wireguard.com/)) runs as a virtualised bridge between this and the auxiliary server hosted elsewhere.
 
Running Kubernetes on self-managed virtualisation -- and in turn on bare-metal -- is fairly unorthodoxy these days -- not to mention the likes of managed Kubernetes setups such as those from [Google](https://cloud.google.com/kubernetes-engine/) and [DigitalOcean](https://www.digitalocean.com/). A wise production setup would at least not involve maintaining one's own hypervisor -- which I did in this setup. This setup is therefore by no means commercially-sensible for most use-cases, but rather as a personal hobby. 

Some infrastructural notes for the setup:

* The process of setting up `libvirt` to run KVM in a segregated private subnet and managing it with `virsh` were fairly [well](https://help.ubuntu.com/community/KVM/Installation)-[documented](https://www.cyberciti.biz/faq/installing-kvm-on-ubuntu-16-04-lts-server/).

* Setting up Kubernetes [master and worker nodes](https://kubernetes.io/docs/setup/independent/install-kubeadm/) with Docker as [container runtime](https://kubernetes.io/docs/setup/cri/), [joining them together](https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/#pod-network), and [wiring their pods together](https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/#pod-network) with Calico was surprisingly easy, as the bare-metal setup process is very mature.

* The biggest pain point of running a bare-metal setup of Kubernetes is the lack of a ready-made load-balancer and ingress solution, such as [ELB/NLB]([https://aws.amazon.com/elasticloadbalancing/](https://aws.amazon.com/elasticloadbalancing/)) available when your cluster runs on AWS EC2. 
    * Instead, I used [MetalLB](https://metallb.universe.tf/tutorial/layer2/) on Layer 2 routing mode to front the Cluster IP of an NGINX internal ingress service, with MetalLB's own ingress subnet forwarded via NAT to an external ingress IP. 
    * The BGP mode of MetalLB would be really nice to have, but it is unfortunately not compatible with Calico's BGP setup. 

* I use [GlusterFS](https://www.gluster.org/) as a replicated storage backend, which in this setup is not really redundant since they run on the same physical hard drive of the host server. But in a more budget-accommodating setup this can be easily distributed. GlusterFS is wired into Kubernetes as an endpoint for persistent volumes. 

For each of my existing personal projects, I wrote `Dockerfile`s and supporting `Makefile`s to enable them to be containerised. These mostly run with three replicas for load-balancing. These projects include:

* [My personal page](https://scy.email) which is now served by an [NGINX/Alpine container](https://github.com/icydoge/scy.email) deployment.

* [My personal blog](https://blog.scy.email) (the site you are reading now) which is now served by another [NGINX/Alpine container](https://github.com/icydoge/blog.scy.email) deployment.

* The [documentation site](https://covertmark.com) for my Master's dissertation project CovertMark, which is now served by yet another [NGINX/Alpine container](https://github.com/icydoge/CovertMark/tree/master/doc) deployment.

* The front-end and RESTful API backend of my personal image sharing service [Yronwood](https://github.com/icydoge/yronwood/), which I wrote from scratch in Golang to replace the old PHP/MySQL-based [Lychee](https://github.com/LycheeOrg/Lychee/) that was way too painful to containerise.

* Some static and PHP sites I host for family and friends on a _pro bono_ basis.

Due to the non-distributed nature of most of these setups, these projects don't really benefit from additional redundancy and resiliency which Kubernetes is supposed to provide, but this hopefully serves as a good technical demonstrator for the feasibility of managing small scale projects in Kubernetes.

