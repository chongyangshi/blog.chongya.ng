Title: A Spoilt Ballot, and maybe a Security Audit
Date: 2016-06-10 21:27
Category: Journal

In case you are not aware, the [university's student union YUSU](https://yusu.org) has recently conducted a [referendum](https://www.yusu.org/blog/view/1572) on the continuation of its membership with the [National Union of Students](http://www.nus.org.uk/). While I cannot care less about the bits and bobs of why it is taking place, with the results announced, there is something interesting on the (electronic) ballot.

Among the votes cast, 1461 voted in favour of staying in, while 1233 voted to leave, with 46 abstentions. However, there is also one single spoilt ballot (which seems bizarre for electronic voting), for which YUSU has provided a seemingly ambiguous explanation:

> A spoilt ballot happens when a person casts a vote but not for one of the candidates listed. The electronic ballot is more technical but it is still possible to write a different candidate name (...)  the vote will still be recorded, but as it's not a valid candidate the ballot gets marked as spoilt (...)

Weird, isn't it? When the web-based voting system provides you with three options (Remain, Leave, Abstention), what else could you go? 

As it turns out, there is a way, which really should not be possible with a competent web developer. In the [Report from the Deputy Returning Officer](http://www.yusu.org/docs/yusu-nus-referendum-report-2016.pdf), detailed statistics are provided by attributes such as gender and year of study. Because only one person has spoilt the ballot, it is possible to determine that the person is a third year Computer Science undergraduate student, who is male and registered to Langwith College (all from public statistics). In fact, a few of us know who he is, but it is not appropriate to name the hero here.

However, my speculation of how this was done has been partly confirmed. The vote page is basically an HTML form with a input field containing the option chosen, whose value is dependent on the user selection among the provided options. It is very likely that YUSU's system does not actually check if the value submitted by the HTML form is among the available options. Therefore, it is possible for the user to modify the form and send any value to the system. I am fairly certain that this is not an intentional design, as otherwise there will be an input field "Non of the above:" provided along with the given options. 

While I agree that treating a "modified" ballot as spoilt is the only appropriate way, I do really hope that the user input is either [escaped](https://en.wikipedia.org/wiki/Secure_input_and_output_handling) or bound to parameters before accepted into the database, otherwise any person could manipulate the database in whatever way they want, and gain access to sensitive student data available to YUSU (and I also hope that YUSU is not using the likes of `mysql_real_escape_string`). 

I still wonder if there are other parts of the YUSU website and systems that have lurking flaws just like this that may unearth one day. Suggestion? Get a security audit.
