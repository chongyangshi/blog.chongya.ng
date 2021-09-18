Title: Mixed IKEv2 / IKEv1 Cisco IPSec VPN Server with No User Certificates
Date: 2016-11-20 00:26
Category: Technical

Also known as: **Moving on from racoon to strongSwan, with back compatibility**.

After an afternoon (well, mostly evening since I woke up at 3 pm) of troubleshooting, I figured out why iOS 9+ and OS X 10.11+ are having slow connection issues with [racoon](http://ipsec-tools.sourceforge.net/)-powered Cisco IPSec IKEv1 VPNs, and why it is really the time to move on to strongSwan and IKEv2. And I will also provide a solution to deploy a strongSwan mixed IKEv2+IKEv1 server that would work for almost all clients.

#### Trouble with racoon
After getting an iOS 9 and an iOS 10 device, I noticed a considerable slow down in their "Cisco IPSec" (IKEv1) VPN connections to my servers. After some IRC discussion today, I decided to take a look, and found the culprit.

Apparently, Apple is deprecating the widely used (but also old) AES128/DES, HMAC_SHA1 and DH Group 2/modp1024 configuration set for IKEv1. They are old, and many parts of the configuration set are getting onto the brink of insecurity. However, this is still the highest supported configuration set for vpnc  -- default IKEv1 client with Network Manager support on Ubuntu, released in 2008(!), iOS 8 and earlier, Mac OS X 10.10 and earlier, and many others. This does not mean that this configuration set will not work on iOS 9+ and OS X 10.11+, but as they will try their preferred configurations (AES256, SHA512 and modp2048) first, and then many others in between, and finally to our old configurations, this makes the handshake time to be 10-20 second in my case, which is utterly bad. 

racoon / ipsec-tools is also very old, and while Japan's Network Information Centre (JPNIC) has a [fork](http://www.racoon2.wide.ad.jp/w/?TheRacoon2Project) of racoon that supports IKEv2, I think [strongSwan](https://www.strongswan.org/) is a far better supported, tested and safer option to move on to. However, a lot of aforementioned legacy devices also do not support IKEv2, so we need to deploy a mixed IKEv2+IKEv1 server to put everything into one server.

#### The Painful strongSwan
The reason that I have avoided strongSwan for so long is that the recommended client certificate authentication being difficult to deploy and get right for a private server without access to a trusted client certificate issuing facility. An entire self-signed trust environment would mean that a self-signed CA would have to be installed on your client devices (bad) and it is difficult to protect your CA private key from chances of compromise (bad). If your CA's private key somehow becomes compromised, then an attacker can easily issue certificates for websites that your clients would trust while visiting. 

Now, we don't have to have client certificates for EAP key exchange/authentication (which is what I will use), but instead usernames and passwords. However, you will still need a server certificate that can either be self-signed or purchased. 

If you choose to create a CA and self-sign your server certificate, you still have the problem mentioned above. Therefore, I have chosen to use a purchased and trusted certificate. My GoGetSSL reseller account allows me to pay $11.25 for a three year PositiveSSL certificate, but you can also get one for free from [Let's Encrypt](https://letsencrypt.org/), just follow their `certbot-auto` instructions and make symbolic links from Let's Encrypt directories to the relevant directories under `/etc/ipsec.d/`. Make sure that auto-renewal works for Let's Encrypt, otherwise your server may suddenly stop working! 

#### Deploying strongSwan
If you have skipped the large blocks of text above, go and read the paragraph just before this section heading, otherwise you will be confused about the certificates used ("hey where are the instructions about making certificates?").

**Sorting out certificates**

After obtaining a set of trusted certificates in whatever way, you should have the following certificate and key files (names are examples but don't matter):

* CA Certificate (provided by your certificate issuer): `ca.crt`
* CA Intermediate Certificate(s) (there is usually one, since CAs mostly issue certificates through their intermediates only, and maybe two or more) `intermediate1.crt`, `intermediate2.crt` (if exists), ...
* Server Certificate (usually provided by your certificate issuer): `server.crt`
* Server Certificate Key (should not have left your server at this point!): `server_key.pem`

Place (or in the case of Let's Encrypt certificates symbolic link) them as followed:

* `ca.crt`, `intermediate1.crt`, `intermediate2.crt` (if exists, and so on if more) to `/etc/ipsec.d/cacerts/`
* `server.crt` to `/etc/ipsec.d/certs/`
* `server_key.pem` to `/etc/ipsec.d/private/`

Make sure that `ca.crt` along with all the intermediate certificates (`intermediate1.crt` etc) would form the complete certificate chain for your server certificate, otherwise your client may not trust it if it cannot follow the broken chain!

Also, make sure that all these certificates are read-only when stored.

**Installing strongSwan**

Now, I am a Ubuntu user and enjoy access to a wide range of pre-built packages, therefore I am just going to use the package manager to install strongSwan, since the default build works for my purposes. If you use another distribution, or have special requirements with the installation, then you will need to [download the source](download.strongswan.org) and build it yourself.

    apt-get install strongswan libstrongswan libstrongswan libstrongswan-standard-plugins libcharon-extra-plugins

And it's done, no fuss.

**Configuring strongSwan**

First move the IPSec configurations to their backups, since we are starting anew:

    mv /etc/ipsec.secrets /etc/ipsec.secrets.old
    mv /etc/ipsec.conf /etc/ipsec.conf.old

Figure out your server's public IP now (e.g. find the right one in `ifconfig`), since we will need it in a moment. For compatibility reasons, the domain hostname your certificate was issued for should be resolved to your server (as observed from the outside, so no CDN in the middle). We will use this hostname instead of the IP address to configure strongSwan. In this post, the example will be `vpn.ebornet.com`, change this to your server's when editing the configuration.

Edit `/etc/ipsec.conf`:

    config setup
        
        # This permits multiple logins with the same username/password, set this to yes if you don't like this.
        uniqueids=no

    conn %default

        # Using advanced ciphers. 
        ike=aes256gcm16-aes256gcm12-aes128gcm16-aes128gcm12-sha256-sha1-modp2048-modp4096-modp1024,aes256-aes128-sha256-sha1-modp2048-modp4096-modp1024,3des-sha1-modp1024!
        esp=aes128gcm12-aes128gcm16-aes256gcm12-aes256gcm16-modp2048-modp4096-modp1024,aes128-aes256-sha1-sha256-modp2048-modp4096-modp1024,aes128-sha1-modp2048,aes128-sha1-modp1024,3des-sha1-modp1024,aes128-aes256-sha1-sha256,aes128-sha1,3des-sha1!

        dpdaction=clear
        dpddelay=35s
        dpdtimeout=2000s

        keyexchange=ikev2
        auto=add
        rekey=no
        reauth=no
        fragmentation=yes
        #compress=yes

        # left - local (server) side
        leftcert=server.crt # Filename of certificate located at /etc/ipsec.d/certs/
        leftsendcert=always
        leftsubnet=0.0.0.0/0,

        # right - remote (client) side
        eap_identity=%identity
        rightsourceip=10.1.1.0/24
        rightdns=8.8.8.8 #Change it to another public DNS if required.

    # Windows and BlackBerry clients
    conn ikev2-mschapv2
        rightauth=eap-mschapv2

    # Apple clients 
    conn ikev2-mschapv2-apple
        rightauth=eap-mschapv2
        leftid=vpn.ebornet.com #Change this to your certificate hostname. 

    conn ikev1group
        aggressive = yes # Not good, but standard practise and required to make IKEv1 work on most consumer clients such as iOS.
        keyexchange=ikev1
        authby=xauthpsk
        xauth=server
        left=%defaultroute
        leftsubnet=0.0.0.0/0
        leftfirewall=yes
        right=%any
        rightsubnet=10.1.2.0/24
        rightsourceip=10.1.2.0/24
        rightdns=8.8.8.8 #Change it to another public DNS if required.
        auto=add

A couple of things to note when copy-pasting:

* We are using local ranges `10.1.1.0/24` for IKEv2 and `10.1.2.0/24` for IKEv1. If you want to change this, change their occurrences in the above file, as well as in the iptables rules followed soon.
* I use Google's Public DNS (`8.8.8.8`) for pushing to clients, if you don't like using this, change them to the one you like.
* Change the domain in `leftid=vpn.ebornet.com` to the correct and resolved certificate hostname for your server, otherwise iOS and OS X clients won't work.

Edit `/etc/strongswan.conf` by adding a line as shown:
    
    charon {
            load_modular = yes
            i_dont_care_about_security_and_use_aggressive_mode_psk = yes
            #Add the above, again not good, but required for most IKEv1 clients to function.
            plugins {
                    include strongswan.d/charon/*.conf
            }
    }

Edit `/etc/ipsec.secrets`:
    
    #For IKEv2:
    : RSA server_key.pem
    v2user : EAP "SomeComplicatedPassword" 
    # Add more username (e.g, v2user) and password (e.g. SomeComplicatedPassword) pairs in this format.

    #For IKEv1:
    99.99.99.99 v1group : PSK "SomeStrangeSharedKey!"
    #99.99.99.99 is your server IP, v1group is the IKEv1 group name, SomeStrangeSharedKey! is the pre-shared key for the group.
    v1user : XAUTH "AnotherComplicatedPassword"
    # Add more username (e.g, v1user) and password (e.g. AnotherComplicatedPassword) pairs in this format.

Things to note when copy-pasting:

* For IKEv2, if your server certificate key is not `/etc/ipsec.d/private/server_key.pem`, change it to the right file name.
* Change `99.99.99.99` to the IP of your server.
* v1group is the IKEv1 group name that you can change.
* Customise usernames and passwords in the above formats.

Yes, plain text usernames and passwords are not great, but absent deploying a Radius server this is saving time for a private server. Compromise of a user's password does not compromise the EAP key exchange for other users. 

Save everything, and we are all done.

**Configure iptables and traffic forwarding**

Depends on whether you like using things like `iptables-persistent` or plug everything into `/etc/rc.local`, I would apply the following iptables rules:

    iptables --table nat --append POSTROUTING --jump MASQUERADE
    iptables -t nat -A POSTROUTING -s 10.1.1.0/24 -j SNAT --to-source 99.99.99.99 #Change to your server IP.
    iptables -t nat -A POSTROUTING -s 10.1.2.0/24 -j SNAT --to-source 99.99.99.99 #Change to your server IP.
    iptables -I FORWARD -m policy --dir in --pol ipsec --proto esp -j ACCEPT
    iptables -I FORWARD -m policy --dir out --pol ipsec --proto esp -j ACCEPT

Remember to change `99.99.99.99` to the correct server IP of yours.

I have plugged them into `/etc/rc.local` before the `exit` line so that they would be automatically reapplied on reboot, if you would also like to do this, now is the time.

Edit `/etc/sysctl.conf`:

Uncomment the line for enabling IPv4 forwarding, so that it would look like this:

    net.ipv4.ip_forward=1

And apply the change:

    sysctl -p

If you are not using a Debian/Ubuntu distribution, the correct thing to do here may vary.

Now we just need to restart strongSwan, depends on what manages your services:

    #For systemd:
    systemctl restart strongswan
    #For Ubuntu upstart:
    service strongswan restart

You may wish to check the logs to make sure that everything works, and if they do, then great, we are done.

**A note on EAP**

Yes, EAP key exchange is arguably not as secure as certificate authentication, but it saves so much hassle in things randomly not working because of improper client profile installation (potentially dangerous) or the inability to issue trusted client certificates. I consider this as a trade off.

**A special note on wildcard certificates**

Despite strongSwan developers being [adamant](https://wiki.strongswan.org/issues/794#note-3) about not supporting wildcard certificates (such as `CN=*.ebornet.com`), there is a way to get it work.

If you use a wildcard certificate, in `/etc/ipsec.conf`, set `leftid` under `ikev2-mschapv2-apple` as the wildcard form of your domain, such as `*.example.com`, and when connecting from your client (more below), set server name as usual to be the resolved name of your server (such as `vpn.example.com`), but put `*.example.com` in as the remote ID. This is tested to work on iOS at the very least.

#### Now Configure the Clients

The guides are rough, please follow client system instructions.

**Windows 7/8/10**

Go to your Control Panel (the full one) -> Network and Sharing Centre -> Create a new connection or network -> Set up a VPN (wording varies).

Set server address to the certificate hostname resolved to your server, and some description of your choice. And continue until the wizard finishes -- we still need to change a few adaptor settings.

Now go to `Change Adaptor Settings`, right click on your newly-created VPN connection, choose `Properties`, and go through the tabs. Make sure that the type of the VPN is set to IKEv2, we use EAP and MS-CHAPv2, make it save your credentials but do not use system login credentials. Choose require encryption. Now we can click `OK`.

Now double click on your VPN connection, you will be prompted the IKEv2 username and password that you have set earlier. Enter them and you should be connected.

**iOS 9+ and OS X 10.11+**

Go to create a new VPN configuration (location varies), and set a description of your choice, `Server` as the certificate hostname resolved to your server (and `Remote ID` the same); `Local ID` does not matter in this case (I think), but I have set it to my IKEv2 username. 

For Authentication, use `Username` for `User Authentication`, and enter your IKEv2 username and password set earlier. Click `Done` and it should be ready to connect.

**iOS 8**

iOS 8 supports IKEv2, but does not have a GUI for it yet. If you are still using iOS 8, you need to configure it with a configuration profile, see [the documentation](https://wiki.strongswan.org/projects/strongswan/wiki/AppleIKEv2Profile) for more details.

You can of course, also choose to use "Cisco IPSec" (IKEv1), using the server hostname or IP, IKEv1 username and its password, group name and its shared secret as set earlier.

**iOS 7 or earlier and OS X 10.10 or earlier**

Out of luck, they have no native support for IKEv2. 

However, you can use "Cisco IPSec" (IKEv1), using the server hostname or IP, IKEv1 username and its password, group name (e.g. `v1group`) and its shared secret as set earlier.

**Android (tested on 5.1+)**

strongSwan has an official VPN application for Android, download it from Play Store [here](https://play.google.com/store/apps/details?id=org.strongswan.android), it's free.

Configuration is straightforward, use EAP mode, and your server certificate hostname, your IKEv2 username and password. 

**Linux Desktop (in this case, Ubuntu 16.04)**

On my Ubuntu 16.04 desktop, the default binary packages of `strongswan-nm` will **not** work, as they were not built correctly. To use IKEv2 on Ubuntu 16.04 desktop, manual builds of strongSwan and NetworkManager-strongswan are required. The followed is what I did and finally worked, if it does not work for you (good chances), please skip this part and try IKEv1 instead.

    # Build and install strongSwan
    cd ~/Downloads
    wget https://download.strongswan.org/strongswan-5.5.1.tar.gz
    tar zxvf strongswan-5.5.1.tar.gz
    cd strongswan-5.5.1
    ./configure --sysconfdir=/etc --prefix=/usr --libexecdir=/usr/lib --disable-aes --disable-des --disable-md5 --disable-sha1 --disable-sha2 --disable-fips-prf --disable-gmp --enable-openssl --enable-nm --enable-agent --enable-eap-gtc --enable-eap-md5 --enable-eap-mschapv2 --enable-eap-identity
    make
    sudo make install

    #Test charon-nm, make sure that it does not output any errors! (no output is fine):
    /usr/lib/ipsec/charon-nm
    
    # Build and install NetworkManager-strongswan:
    cd ~/Downloads
    wget https://download.strongswan.org/NetworkManager/NetworkManager-strongswan-1.4.1.tar.bz2
    tar xjvf NetworkManager-strongswan-1.4.1.tar.bz2
    ./configure --sysconfdir=/etc --prefix=/usr --with-charon=/usr/lib/ipsec/charon-nm  #Specifying charon-nm location seems to make it work?
    make
    sudo make install

And after restarting the computer, use Network Manager to configure a "strongswan" VPN connection, use your server certificate, as well as EAP mode and your IKEv2 username and password.

I have no idea about other distributions, they may have pre-built packages that work out of the box. Or maybe you don't need Network Manager like I do, then there's no need of getting strongSwan to work with Network Manager.

To use the supported IKEv1 client on Ubuntu, install `network-manager-vpnc-gnome`, and set up a connection in the Network Manager using the server hostname or IP, IKEv1 username and its password, group name (e.g. `v1group`) and its shared secret as set earlier.



