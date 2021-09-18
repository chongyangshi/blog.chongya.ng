Title: Running a Low-Cost, Distributed Kubernetes Cluster on Bare-Metal with WireGuard 
Date: 2019-12-26 20:25
Category: Technical

### Background

[WireGuard]([http://wireguard.com/](http://wireguard.com/)) is a very well-abstracted and performant way of establishing site-to-site VPNs across multiple private networks over the internet. It exposes itself as a virtualised network interface on the local system, and does the vast majority of networking work within kernel space. Therefore the user can leverage system-managed IP routing to easily direct traffic down the WireGuard tunnel into private networks running on the other side of the internet.

These characteristics make it ideal to use WireGuard for tunnelling Calico traffic across the internet, between Kubernetes nodes within the same cluster but running at different sites, each with their own private network. In my own use case, I run a [private Kubernetes cluster](https://blog.scy.email/running-a-personal-kubernetes-cluster-with-calico-connected-services-on-bare-metal.html) running the majority of my personal projects as microservice workloads. These workloads run as Kubernetes pods within one Calico CIDR, no matter which node at which location they run on.

Under this low-budget use-case, in addition to operating a really cheap dedicated server running a self-managed KVM hypervisor (where most of my Kubernetes cluster lives), I'm also always on the look out for high-resource, low-cost virtual private server (VPS) providers which are reputable. After renting VPS from one of these providers, the VPS can be used as a satellite server running a Kubernetes node on its own, connected to the rest of the cluster through WireGuard.

To put this strategy into perspective, while a `c4.large` AWS EC2 instance (a minimum spec for Kubernetes nodes) with [committed savings plan pricing](https://aws.amazon.com/savingsplans/pricing/) costs more than $1000 year (before EBS and egress traffic cost are even factored in),  my satellite servers with the same resource specification costs me between $40 and $80 a year each, with generous amounts of local storage and egress traffic included.

By distributing workloads out between different providers, without losing the benefits of running all workloads within one logical cluster, I can effectively implement the concept of "availability zones" provided by [IaaS]([https://en.wikipedia.org/wiki/Infrastructure_as_a_service](https://en.wikipedia.org/wiki/Infrastructure_as_a_service)) equivalent to those offered by providers like AWS. Hosting workloads across multiple availability zones provide redundancy between physical sites of infrastructures, while still allowing private network traffic to flow in-between.

Of course, the hypervisor hardware running my budget VMs will not be as reliable as those of AWS EC2 nodes, and these budget providers, despite reasonable reputation of longevity, are still more likely to suddenly go bankrupt compared to AWS. The purpose of my exercise is to operate a bare-metal cluster as cheaply as possible. 

### Architecture
![Multi-Site Cluster Network](https://i.doge.at/uploads/big/df70988d0dedf2f7130702a04783a4db.png)

This setup represents a mix of one local private network containing several nodes, connected to satellite nodes hosted elsewhere by WireGuard. WireGuard runs as a separate VM instance (`10.100.0.88` with DNAT ingress for the WireGuard port on the hypervisor host) responsible for NAT'ing packets traversing to and from satellite servers. 

On satellite servers running Kubernetes nodes, it is necessary for each of them to run WireGuard locally, as we don't want any Kubernetes control plane (cluster management) traffic to go over the internet without additional protection. 

Normally, connecting several networks together requires one or more bridge servers running NAT. However, NAT and local BGP setups (as used by Calico on TCP 179) together generally cause weird behaviours. I discovered that BGP messages _traversing_ networks work fine under local NAT rules of any WireGuard terminal instances they pass through, so long as the terminal instance(s) belong to either the source or the destination network. However, if the terminal instance is used as a "bridge" peer for two other WireGuard peers not connected via their own endpoints, Calico (or rather, bird) will complain that the source of BGP message was from the incorrectly masquaraded bridge peer, due to NAT on the bridge peer; and refuse to update local routes correctly. 

Therefore, it is still necessary for WireGuard interfaces on all networks and discrete satellite servers to have direct paths to each other for peering to work; which requires all of these interfaces to have all other interfaces configured as direct WireGuard peers. This introduces a menial amount of reconfiguration of all WireGuard interfaces each time a new network (or discrete satellite server) is added into the cluster.

This setup does however bring benefits, as NAT will not be required in either direction on any bridge peers. Through observation, both control plane and container network traffic work fine on just static routes to all other internal subnets. Manually configuring static routes on all nodes is still a pain, but not using NAT between internal subnets helps avoiding many other problems.

While it is theoretically possible to not use multiple internal subnets at all, and instead run WireGuard on all nodes in `10.100.0.0/25`, for Kubernetes control plane to work, this alternative will require all nodes in this subnet to hold a full view of all WireGuard installations within the cluster, including each installation's public internet endpoint and their internal IP); additionally any WireGuard instances running within local networks will need to have a DNAT port on the hypervisor's ingress interface. This quickly becomes unmanageable, not to mention increased points of failures. 

In the setup adopted, to connect any additional local network (say, `10.101.0.0/25`) into the cluster, it is necessary to create a new WireGuard Terminal instance in the new network, and update the WireGuard configurations of terminal instances of existing networks, as well as those of satellite servers running discrete Kubernetes nodes as shown.

### What worked and what didn't

Kubernetes cluster management traffic (running on node network, which is a combination of `10.100.0.0/25` and `172.16.16.0/24`) consistently worked as expected. Satellite nodes in `172.16.16.0/24` behave as if they were part of the cluster, and talk to the `apiserver` on master node in in `10.100.0.0/25` correctly. This did require a minor tweak of `kubeadm`'s configuration after the initial `kubeadm join` (below). 

    $ cat /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
    [Service]
    (...)
    Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml --node-ip 172.16.16.3"
    (...)

This process also involves overcoming a common MTU issue when tunnelling encapsulated packets, which would have caused packets larger than MTU to be dropped incorrectly. To resolve this, I recommend:

* Make all physical ethernet interfaces, and virtualized ethernet interfaces of satellite workers use MTU = 1500.
* Setting `MTU = 1360` in your `[interface]` configuration of all WireGuard installations
* Configure Calico to use MTU = 1300:

 
        $ kubectl get cm -n kube-system calico-config -o yaml
        apiVersion: v1
        data:
        calico_backend: bird
        cni_network_config: |-
            {
            "name": "k8s-pod-network",
            "cniVersion": "0.3.1",
            "plugins": [
                {
                "type": "calico",
                (...)
                "mtu": 1300,
                (...)
        typha_service_name: none
        veth_mtu: "1300"
        kind: ConfigMap
        (...)

Once MTU is reconfigured, all the `calico-node`'s must be restarted to take on the new MTU.
   
However, **the problem happens** once workloads have been deployed into the satellite servers, RPC packets to and from these workloads do not always successfully reach their destinations, as shown in the `tcpdump` output below:

    $ sudo tcpdump -i wg0 port not 6443 and port not 179 and port not 10250 -vv -n
    tcpdump: listening on wg0, link-type RAW (Raw IP), capture size 262144 bytes
    18:52:54.523437 IP (tos 0x0, ttl 63, id 44293, offset 0, flags [DF], proto IPIP (4), length 80)
        172.16.16.3 > 10.100.0.4: IP (tos 0x0, ttl 63, id 65437, offset 0, flags [DF], proto TCP (6), length 60)
        192.168.29.129.38978 > 192.168.1.7.80: Flags [S], cksum 0x78fb (correct), seq 1021627257, win 25200, options [mss 1260,sackOK,TS val 818412491 ecr 0,nop,wscale 7], length 0
    18:52:54.523878 IP (tos 0x0, ttl 62, id 23546, offset 0, flags [DF], proto IPIP (4), length 80)
        10.100.0.4 > 172.16.16.3: IP (tos 0x0, ttl 63, id 0, offset 0, flags [DF], proto TCP (6), length 60)
        192.168.1.7.80 > 192.168.29.129.38978: Flags [S.], cksum 0x4116 (correct), seq 991018110, ack 1021627258, win 24960, options [mss 1260,sackOK,TS val 4138093197 ecr 818412491,nop,wscale 7], length 0
    18:52:54.527993 IP (tos 0x0, ttl 63, id 44295, offset 0, flags [DF], proto IPIP (4), length 72)
        172.16.16.3 > 10.100.0.4: IP (tos 0x0, ttl 63, id 65438, offset 0, flags [DF], proto TCP (6), length 52)
        192.168.29.129.38978 > 192.168.1.7.80: Flags [.], cksum 0xcfd0 (correct), seq 1, ack 1, win 197, options [nop,nop,TS val 818412496 ecr 4138093197], length 0
    18:52:54.528043 IP (tos 0x0, ttl 63, id 44296, offset 0, flags [DF], proto IPIP (4), length 146)
        172.16.16.3 > 10.100.0.4: IP (tos 0x0, ttl 63, id 65439, offset 0, flags [DF], proto TCP (6), length 126)
        192.168.29.129.38978 > 192.168.1.7.80: Flags [P.], cksum 0x8e99 (correct), seq 1:75, ack 1, win 197, options [nop,nop,TS val 818412496 ecr 4138093197], length 74: HTTP, length: 74
        GET / HTTP/1.1
        Host: 192.168.1.7
        User-Agent: Wget
        Connection: close

    18:52:54.528482 IP (tos 0x0, ttl 62, id 23548, offset 0, flags [DF], proto IPIP (4), length 72)
        10.100.0.4 > 172.16.16.3: IP (tos 0x0, ttl 63, id 27417, offset 0, flags [DF], proto TCP (6), length 52)
        192.168.1.7.80 > 192.168.29.129.38978: Flags [.], cksum 0xcf83 (correct), seq 1, ack 75, win 195, options [nop,nop,TS val 4138093202 ecr 818412496], length 0
    18:52:54.528787 IP (tos 0x0, ttl 62, id 23549, offset 0, flags [DF], proto IPIP (4), length 388)
        10.100.0.4 > 172.16.16.3: IP (tos 0x0, ttl 63, id 27418, offset 0, flags [DF], proto TCP (6), length 368)
        192.168.1.7.80 > 192.168.29.129.38978: Flags [P.], cksum 0xcd1e (correct), seq 1:317, ack 75, win 195, options [nop,nop,TS val 4138093202 ecr 818412496], length 316: HTTP, length: 316
        HTTP/1.1 200 OK
        Server: nginx/1.15.12
        Date: Thu, 19 Dec 2019 18:52:58 GMT
        Content-Type: text/plain
        Content-Length: 145
        Connection: close
        Content-Type: text/plain

        (body removed)
    18:52:54.528861 IP (tos 0x0, ttl 62, id 23550, offset 0, flags [DF], proto IPIP (4), length 72)
        10.100.0.4 > 172.16.16.3: IP (tos 0x0, ttl 63, id 27419, offset 0, flags [DF], proto TCP (6), length 52)
        192.168.1.7.80 > 192.168.29.129.38978: Flags [F.], cksum 0xce46 (correct), seq 317, ack 75, win 195, options [nop,nop,TS val 4138093202 ecr 818412496], length 0
    18:52:54.532556 IP (tos 0x0, ttl 63, id 44297, offset 0, flags [DF], proto IPIP (4), length 72)
        172.16.16.3 > 10.100.0.4: IP (tos 0x0, ttl 63, id 65440, offset 0, flags [DF], proto TCP (6), length 52)
        192.168.29.129.38978 > 192.168.1.7.80: Flags [.], cksum 0xce37 (correct), seq 75, ack 317, win 206, options [nop,nop,TS val 818412501 ecr 4138093202], length 0
    18:52:54.534390 IP (tos 0x0, ttl 63, id 44298, offset 0, flags [DF], proto IPIP (4), length 72)
        172.16.16.3 > 10.100.0.4: IP (tos 0x0, ttl 63, id 65441, offset 0, flags [DF], proto TCP (6), length 52)
        192.168.29.129.38978 > 192.168.1.7.80: Flags [F.], cksum 0xce33 (correct), seq 75, ack 318, win 206, options [nop,nop,TS val 818412503 ecr 4138093202], length 0
    18:52:54.534595 IP (tos 0x0, ttl 62, id 23551, offset 0, flags [DF], proto IPIP (4), length 72)
        10.100.0.4 > 172.16.16.3: IP (tos 0x0, ttl 63, id 27420, offset 0, flags [DF], proto TCP (6), length 52)
        192.168.1.7.80 > 192.168.29.129.38978: Flags [.], cksum 0xce38 (correct), seq 318, ack 76, win 195, options [nop,nop,TS val 4138093208 ecr 818412503], length 0
    18:52:58.072372 IP (tos 0x0, ttl 63, id 15157, offset 0, flags [DF], proto IPIP (4), length 80)
        172.16.16.3 > 10.100.0.40: IP (tos 0x0, ttl 63, id 4012, offset 0, flags [DF], proto TCP (6), length 60)
        192.168.29.129.51108 > 192.168.2.18.80: Flags [S], cksum 0x04d7 (correct), seq 708851696, win 25200, options [mss 1260,sackOK,TS val 2101778737 ecr 0,nop,wscale 7], length 0
    18:52:59.079740 IP (tos 0x0, ttl 63, id 15222, offset 0, flags [DF], proto IPIP (4), length 80)
        172.16.16.3 > 10.100.0.40: IP (tos 0x0, ttl 63, id 4013, offset 0, flags [DF], proto TCP (6), length 60)
        192.168.29.129.51108 > 192.168.2.18.80: Flags [S], cksum 0x00e7 (correct), seq 708851696, win 25200, options [mss 1260,sackOK,TS val 2101779745 ecr 0,nop,wscale 7], length 0
    18:53:01.095792 IP (tos 0x0, ttl 63, id 15313, offset 0, flags [DF], proto IPIP (4), length 80)
        172.16.16.3 > 10.100.0.40: IP (tos 0x0, ttl 63, id 4014, offset 0, flags [DF], proto TCP (6), length 60)
        192.168.29.129.51108 > 192.168.2.18.80: Flags [S], cksum 0xf906 (correct), seq 708851696, win 25200, options [mss 1260,sackOK,TS val 2101781761 ecr 0,nop,wscale 7], length 0
    18:53:05.127663 IP (tos 0x0, ttl 63, id 15616, offset 0, flags [DF], proto IPIP (4), length 80)
        172.16.16.3 > 10.100.0.40: IP (tos 0x0, ttl 63, id 4015, offset 0, flags [DF], proto TCP (6), length 60)
        192.168.29.129.51108 > 192.168.2.18.80: Flags [S], cksum 0xe947 (correct), seq 708851696, win 25200, options [mss 1260,sackOK,TS val 2101785792 ecr 0,nop,wscale 7], length 0
    ^C
    14 packets captured
    14 packets received by filter
    0 packets dropped by kernel
    4 packets dropped by interface

What's happening in the above is as followed:

* A pod running on Satellite Server 2 (`172.16.16.3`) tries to make RPC calls to two pods with identical workloads (`192.168.1.7`, `192.168.2.18`) running on Worker 1 (`10.100.0.4`) and Worker 2 (`10.100.0.40`) respectively.
* Both RPC calls were made with encapsulated IP-in-IP packets.
* Encapsulation means that the outer packet headers have source and destination IPs as the IPs of the source (`172.16.16.3`) and destination nodes (`10.100.0.4` or `10.100.0.40`).
* And the inner headers contain virtualized Calico pod IP addresses, with which pods are identified in the service mesh.
* Calico pod on each node knows which local pod is allocated which pod IP, while the pod IP of the target workload is obtained by querying or processing through a service proxy, such as [Envoy](https://www.envoyproxy.io/) or simply the integrated `kube-proxy`.
* Calico on the source node has encapsulated the packet with its source and destination nodes.
* Calico on the destination node is meant to unencapsulate the packet, identify the target pod IP, and route traffic towards the local virtual Calico interface of that pod.
* However, only the packets to `192.168.1.7` pod were delivered to target node's Calico (`10.100.0.4`) at all, **while packets to `192.168.2.18` (last three entries in the dump) on node `10.100.0.40` were "dropped by interface" and never routed to the destination**.

Because encapsulated packets to both `10.100.0.4` and `10.100.0.40` have gone through NAT performed by the WireGuard Terminal instance, and both requests happened nearly simultaneously, it is not a typical NAT-related fault I could recognise; but rather due to some strange interaction between inner workings of WireGuard and encapsulated packets passing through. Note the dropped packets on the interface represent dropped responses to the four retries of the failed request in the tcpdump:

    $ ifconfig wg0
    wg0: flags=209<UP,POINTOPOINT,RUNNING,NOARP>  mtu 1360
        inet 172.16.16.1  netmask 255.255.255.255  destination 172.16.16.1
        unspec 00-00-00-00-00-00-00-00-00-00-00-00-00-00-00-00  txqueuelen 1000  (UNSPEC)
        RX packets 1088693  bytes 370424252 (370.4 MB)
        RX errors 8  dropped 34  overruns 0  frame 8
        TX packets 1237790  bytes 842322648 (842.3 MB)
        TX errors 0  dropped 0 overruns 0  carrier 0  collisions 0

And when switching WireGuard into live debug mode via `echo "module wireguard -p" >/sys/kernel/debug/dynamic_debug/control`, dmesg will show something like:
    
    $ dmesg | grep wireguard | grep userspace
    [  507.175613] wireguard: wg0: Failed to give packet to userspace from peer 2 (xx.xx.xx.xx:7000)
    [  508.180598] wireguard: wg0: Failed to give packet to userspace from peer 2 (xx.xx.xx.xx:7000)

Where `xx.xx.xx.xx` is the public IP serving as the endpoint of the satellite server.

I have observed this kind of packet drops happening *sporadically*, in *either* direction encapsulated packets flow, on *all* internet-facing WireGuard interfaces within the cluster. Encapsulated packets can be dropped while standard TCP packets pass through the same link in the same direction just fine.

Because my cluster has a very low volume of inter-service RPC traffic, I noticed that this issue tends to surface after a period during which no encapsulated packets passed through (Calico's keep-alive BGP packets are not encapsulated themselves, and therefore no encapsulated packets happen in the background). I am not very familiar with inner workings of Linux kernel and encapsulated traffic, so if you have any idea what might be happening here, please det me know.

### Solution: Hold the door

Because in-built Kubernetes health checks are always uni-directional, for this particular WireGuard problem where encapsulated packets can be randomly blocked in either direction, it was not sufficient to rely on health checks to keep the paths open. 

As a result, I wrote and deployed a Go microservice [Wylis](https://github.com/chongyangshi/wylis) as a <del>hack</del> workaround. Wylis runs as a Kubernetes Daemonset, which means that it runs as a pod on every node in the cluster. It does the following things:

* Periodically polls Wylis pods on all other nodes with fresh Calico TCP connections to keep the paths open
* Emits [Prometheus](https://prometheus.io) metrics to help measuring fine-grained request success and latency across the cluster
* Periodically updates its knowledge of other Wylis pods through in-cluster Kubernetes API 

Following initial running with a polling period of 10 seconds, metrics emitted suggest that Wylis is working very well in keeping RPC traffic reachable across tunnelled networks:

![Request successes and failures](https://i.doge.at/uploads/big/5bce5df617258d7db54c04f9a2927e6b.png)

_No requests with encapsulated packets timed out when travelling through WireGuard under periodic polling._

![Request timings](https://i.doge.at/uploads/big/951795a8bf78b9e3b42228952a6450eb.png)

_Polling requests provide useful timing data on inter-node RPCs._


### Security Warning

By default [kubelet server](https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/) and Kubernetes [NodePorts](https://kubernetes.io/docs/concepts/services-networking/service/#nodeport) will listen on _all_ interfaces on the node, including external-facing interfaces. Normally, this is okay, as Kubernetes nodes are not expected to run with public IPs. But this is not true for our satellite servers, which are VPS servers with public IPs connected into the cluster via WireGuard. Therefore, these ports will be directly exposed on the public-facing network interface (eth0 or similar) unless iptables rules on these interfaces are set to deny ingress by default.

While kubelet server has authentication, your NodePorts may not. So it is extra important that you only allow system services running on the host server to be accessed via the public internet, but not any NodePorts or kubelet ports. The corresponding rules look something like the following:

    iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A INPUT -i eth0 -p tcp -m multiport --dports 22,9301 -j ACCEPT  # SSH and some other system service
    iptables -A INPUT -i eth0 -p udp -m multiport --dports 7000 -j ACCEPT     # WireGuard ingress port 
    iptables -A INPUT -i eth0 -p udp -j DROP
    iptables -A INPUT -i eth0 -p tcp -j DROP
