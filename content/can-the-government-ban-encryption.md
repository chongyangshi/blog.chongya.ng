Title: Can the government simply ban encryption?
Date: 2015-01-22 00:57
Category: Journal

Under the background of nations calling for strict legislations on data retention and surveillance, I attempt to explain as an amateur in cryptography, how this may or may not work, and what can you do to keep your messages safe and secure.

##What happened?

The [Global War on Terror](https://en.wikipedia.org/wiki/War_on_Terror) has never stopped since 9/11, and intelligence agencies' access to private communications have always been controversial. [Edward Snowden's Whistleblowing](https://en.wikipedia.org/wiki/Global_surveillance_disclosures_(2013%E2%80%93present)) has revealed to the world that how the ["Five Eyes"](https://en.wikipedia.org/wiki/Five_Eyes) and other nations' intelligence agencies have implemented surveillance measures -- many being unwarranted, on civilian communications. The recent [terrorist attack on Charlie Hebdo Magazine](https://en.wikipedia.org/wiki/Charlie_Hebdo_shooting) has, once again, provided a chance for governments of nations to call for more legislated powers on intelligence surveillance.

Prime Minister Mr David Cameron has [made an interesting statement](http://www.telegraph.co.uk/technology/internet-security/11340621/Spies-should-be-able-to-monitor-all-online-messaging-says-David-Cameron.html) on legislation on eavesdropping of encryption, which sparked [arguments](http://www.bbc.co.uk/news/technology-30794953) on whether it being practical, or even operable.

In favour of reintroducing the [Communications Data Bill](https://en.wikipedia.org/wiki/Draft_Communications_Data_Bill) (draft stroke down in 2012), Mr Cameron has made the following statement: "...Do we allow terrorists safer spaces for them to talk to each other? I say we don’t – and we should legislate accordingly." He also added: "...in our country, do we want to allow a **means of communication between people** which even *in extremis*, with a signed warrant from the home secretary personally, **that we cannot read?**" This part of his claim has sparked arguments.

I will now attempt to explain, from the viewpoint of an amateur in cryptography, about how this may or may not work.

*Disclaimer: All the information included are compiled from public knowledge and sources. The author introduces the followed knowledge strictly for the public interest in Computer Science and Cryptography. In no way does the author suggest, or encourage the reader to conduct any illegal communications, and conducting such communications can always be deemed as a criminal offence.*

##Can Your Messages Be Read?

In most cases, the answer is yes. There's always one way or another, that can reveal what you have typed into your tiny or big screen. The Electronic Frontier Foundation (EFF, an organisation for the protection of digital rights) has published [a comparison report](https://www.eff.org/secure-messaging-scorecard) of popular instant messaging services, on their security measures and transparency.

It is very clear that most instant messaging services do encrypt your chat messages in transit, mostly through [Transport Layer Security](https://en.wikipedia.org/wiki/Transport_Layer_Security) (TLS), which provides certificate identity authentication and data encryption between you and your messaging service provider's servers. You are probably familiar with Skype, WhatsApp or Snapchat. 

However, many of these providers don't really implement encryption measures of your chat data on their end. A significant [security breach](http://www.independent.co.uk/life-style/gadgets-and-tech/news/the-snappening-snapsave-admits-security-breach-but-says-only-500mb-of-images-leaked-9794488.html) happened to Snapchat last year, where attackers leaked huge amount of user chat log, even uploaded photos (well, your photo disappears from your phone after seconds, but it's not erased from existence on their servers). WhatsApp has gone through [similar problems](https://en.wikipedia.org/wiki/WhatsApp#Security) with the risk of leaking user information. These sort of security breaches have nothing to do with intelligence surveillance, but they do reveal how weak your uploaded data is protected from hacking.

Many providers did implement security measures to encrypt your stored data, in the case of a security breach. However, this does not mean that your data is secured. For example, The aforementioned TLS combines Key-exchange, Cipher Encryption and Data Integrity Verification. However,  Key-exchange through protocols like [RSA](https://en.wikipedia.org/wiki/RSA_(cryptosystem)) or [Diffie-Hellman](https://en.wikipedia.org/wiki/Diffie%E2%80%93Hellman_key_exchange) are vulnerable to [Man-in-the-middle Attack](https://en.wikipedia.org/wiki/Man-in-the-middle_attack) (MITM), which can be performed by a computer in a more privileged position in your network. This computer can be owned by your network administrator, or, unsurprisingly, intelligence agencies with some control over your Internet Service Provider (ISP)'s network. MITM can be performed by impersonating as the other party to both you and the server you intended to communicate with, and reveal the supposedly encrypted data in between. A famous example would be presenting a fake certificate of your server in TLS/SSL handshake. 

Even though [pre-defined trust-store](https://hg.mozilla.org/mozilla-central/raw-file/tip/security/nss/lib/ckfw/builtins/certdata.txt) of trusted [Certificate Authorities](https://en.wikipedia.org/wiki/Certificate_authority) (CA) and [certificate/key pinning](https://www.owasp.org/index.php/Certificate_and_Public_Key_Pinning) can largely prevent MITM from happening, problems can still occur. For example, intelligence (somehow) [gets hold of a certificate wrongfully issued by a trusted CA](https://bugzilla.mozilla.org/show_bug.cgi?id=542689); or your cooperative / malware-infected machine runs a screen/keyboard recording bloatware. (You really shouldn't transmit confidential personal information on your managed work machine)

One of the solutions to these security issues is, bluntly, let's make data encrypted before they are transmitted! Unfortunately, this isn't always successful in keeping the information safe. 

A notable example would be Apple's new iMessage service (iOS 8). Apple has implemented what's called [end-to-end encryption](https://en.wikipedia.org/wiki/End-to-end_encryption), which ensures that a user's message has already been encrypted before being sent via Apple's servers, and Apple "cannot" read what the user has written. However, a [loophole in Apple's security mechanisms](http://blog.quarkslab.com/imessage-privacy.html) has been discovered by researchers at QuarksLab, demonstrating how the secrecy can be broken. Push server's certificate-pinning is not performed at client, making MITM attacks possible, not mentioning that Apple theoretically could perform such attacks themselves to reveal information. Even worse, user's Apple ID credentials are sent in TLS tunnelled clear-text, meaning that if TLS secrecy is broken, someone else can log in as the user, to impersonate as him in future conversations.

So far, we have looked at services that have, or potentially have security flaws. I shall now introduce some possible solutions that are still considered to be secure. (Keep in mind: they might be proven insecure in the future, especially if one of their building blocks, like OpenSSL, invokes a [security exploit](https://en.wikipedia.org/wiki/Heartbleed).)

##What Could Protect Your Messages?

We have seen that improperly ([intentional](https://en.wikipedia.org/wiki/Dual_EC_DRBG#Software_and_hardware_which_contained_the_possible_backdoor) or not) implemented security measures can harm the secrecy of your messages, and established that a well-protected transmission must have secure authentication, encryptions performed by strong ciphers and carefully done verifications. 

It is worth mentioning that public knowledge of how an encryption mechanism work is very important, and the secrecy should be proven by public cryptanalytic research. 

A good example of doing authentication safely is [Cryptocat](https://crypto.cat/). In addition to the implementations of [Off-the-Record Messaging] (https://en.wikipedia.org/wiki/Off-the-Record_Messaging) (OTR) and [Perfect Forward Secrecy](https://en.wikipedia.org/wiki/Forward_secrecy#Perfect_forward_secrecy), there is also a function for two parties of the conversation to exchange personal questions that only the other party would know how to answer, thus establishing a trusted conversation over public relays. The identity authentication is not done mathematically, but by human nature -- even though this could cause badly-designed personal questions vulnerable to [social engineering](https://en.wikipedia.org/wiki/Social_engineering_(security)).

A even better way to communicate securely and effectively is encrypted and authenticated emails done through [GNU Privacy Guard](https://en.wikipedia.org/wiki/GNU_Privacy_Guard) (GnuPG) based on Phil Zimmermann's [Pretty Good Privacy](https://en.wikipedia.org/wiki/Pretty_Good_Privacy) (PGP). In fact, you can start sending PGP signed and encrypted emails today. 

The authentication of identity is done via digital signatures in a [public-key distribution system](https://en.wikipedia.org/wiki/Public-key_cryptography). Your public key, unique to your secret private key, is signed by people who trust you -- who in practise should have seen you in real life and have verified your identity, thus establishing a [web of trust](https://en.wikipedia.org/wiki/Web_of_trust) that people who signed your key vouch for your ownership of that key. This way, people receiving your encrypted message can decrypt the message with their private key, and verify the authenticity of the message with your trusted public key. 

The encryption ciphers and verification mechanisms in GPG are also proven to be robust. If you use GPG/PGP properly, your authentic email (or other messages) will be encrypted and protected before being sent through your email provider, thus preventing others from knowing the content of your email.

You can check [GnuPG](https://www.gnupg.org/) and [Gpg4win](http://www.gpg4win.org/) or [GPGTools](https://gpgtools.org/) to start using GPG/PGP. Remember: **don't sign keys of people who you don't trust** -- otherwise you are breaking the web of trust; and keep your private key(s) encrypted and secure.

##Back to the Question
**So, can there be messages on the Internet that no outsider can read?**

Yes, **but only if you do it properly**, and given that there isn't a court warrant issued to [take over your private key](https://en.wikipedia.org/wiki/Lavabit#Suspension_and_gag_order).

I shall not go into the arguments of whether mass surveillance is beneficial, or whether strict legislations on retention is good. However, when all of these are still legal in the UK (using them legally, of course), I wish to write something that can lead people to more knowledge in this area, which is what I have done today.

*Content correct at the time of writing, to the best knowledge of the author.*

*I do appreciate mistakes being pointed out, please contact doge [AT] ebornet.com in that case.*



