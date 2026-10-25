import Foundation

/// What kind of company a broker is. The ids match `category` in a directory entry's `about:` block (see `tools/describe_brokers.py`).
public enum BrokerCategory: String, CaseIterable, Sendable {
    case people_search, arrests, consumer_reporting, marketing_data, b2b, adtech, healthcare, financial, fraud_identity, real_estate, genealogy, lead_generation, political, recruiting, automotive, location_data, marketing_services, other

    public var title: String {
        switch self {
        case .people_search: return L10n.t("People search")
        case .arrests: return L10n.t("Arrest and court records")
        case .consumer_reporting: return L10n.t("Background screening")
        case .marketing_data: return L10n.t("Marketing data")
        case .b2b: return L10n.t("Business contacts and sales data")
        case .adtech: return L10n.t("Advertising technology")
        case .healthcare: return L10n.t("Healthcare data")
        case .financial: return L10n.t("Financial and credit data")
        case .fraud_identity: return L10n.t("Identity and fraud prevention")
        case .real_estate: return L10n.t("Property and real estate")
        case .genealogy: return L10n.t("Genealogy")
        case .lead_generation: return L10n.t("Lead generation")
        case .political: return L10n.t("Political and nonprofit data")
        case .recruiting: return L10n.t("Recruiting and workforce data")
        case .automotive: return L10n.t("Automotive data")
        case .location_data: return L10n.t("Device and location data")
        case .marketing_services: return L10n.t("Marketing and direct-mail services")
        case .other: return L10n.t("Other data company")
        }
    }
}


/// How bad the worst case can get for one kind of broker, on four counts, each from 0 (none) to 3 (severe).
public struct Harm: Equatable, Sendable {
    public var safety: Int       // physical safety: stalking, harassment, being found
    public var money: Int        // scams, fraud and higher costs
    public var reputation: Int   // jobs, housing, relationships and how others see you
    public var annoyance: Int    // calls, texts, junk mail and spam
}

public extension BrokerCategory {
    /// Where this kind sits in the default order, 1 first. Ranked by how severe the worst case is and how much opting out helps.
    var rank: Int {
        switch self {
        case .people_search: return 1
        case .location_data: return 2
        case .healthcare: return 3
        case .arrests: return 4
        case .marketing_data: return 5
        case .fraud_identity: return 6
        case .financial: return 7
        case .lead_generation: return 8
        case .real_estate: return 9
        case .consumer_reporting: return 10
        case .recruiting: return 11
        case .political: return 12
        case .automotive: return 13
        case .genealogy: return 14
        case .b2b: return 15
        case .adtech: return 16
        case .marketing_services: return 17
        case .other: return 18
        }
    }

    /// The four harms at a glance.
    var harm: Harm {
        switch self {
        case .people_search: return Harm(safety: 3, money: 2, reputation: 2, annoyance: 1)
        case .location_data: return Harm(safety: 3, money: 1, reputation: 2, annoyance: 0)
        case .healthcare: return Harm(safety: 1, money: 1, reputation: 3, annoyance: 1)
        case .arrests: return Harm(safety: 1, money: 1, reputation: 3, annoyance: 0)
        case .marketing_data: return Harm(safety: 1, money: 3, reputation: 1, annoyance: 3)
        case .fraud_identity: return Harm(safety: 1, money: 3, reputation: 2, annoyance: 0)
        case .financial: return Harm(safety: 0, money: 3, reputation: 1, annoyance: 2)
        case .lead_generation: return Harm(safety: 0, money: 2, reputation: 0, annoyance: 3)
        case .real_estate: return Harm(safety: 2, money: 2, reputation: 0, annoyance: 2)
        case .consumer_reporting: return Harm(safety: 0, money: 2, reputation: 3, annoyance: 0)
        case .recruiting: return Harm(safety: 0, money: 2, reputation: 1, annoyance: 2)
        case .political: return Harm(safety: 0, money: 0, reputation: 1, annoyance: 3)
        case .automotive: return Harm(safety: 0, money: 2, reputation: 0, annoyance: 2)
        case .genealogy: return Harm(safety: 2, money: 0, reputation: 1, annoyance: 0)
        case .b2b: return Harm(safety: 0, money: 1, reputation: 0, annoyance: 3)
        case .adtech: return Harm(safety: 0, money: 1, reputation: 1, annoyance: 2)
        case .marketing_services: return Harm(safety: 0, money: 0, reputation: 0, annoyance: 2)
        case .other: return Harm(safety: 0, money: 1, reputation: 0, annoyance: 1)
        }
    }

    /// Why this kind has the place it has in the order.
    var rankReason: String {
        switch self {
        case .people_search: return L10n.t("Anyone can use it for free, and the worst case is physical: a stalker or abuser finding where you live. Removing yourself here does the most for your safety.")
        case .location_data: return L10n.t("Where your phone goes reveals your home, work, faith and health care. It is sold in bulk and cannot be taken back once sold.")
        case .healthcare: return L10n.t("Guesses about your health are the most personal data there is, and you cannot see or correct what they think you have.")
        case .arrests: return L10n.t("A single old or dropped charge can cost a job or a home, and these sites often charge to remove it. The damage is lasting and public.")
        case .marketing_data: return L10n.t("The largest pool of profiles, and the one scammers buy to target you and older relatives. Removing it cuts the most junk and scams.")
        case .fraud_identity: return L10n.t("Detailed identity files are what thieves want and they can be wrong. Some uses are exempt by law, so opting out helps but not completely.")
        case .financial: return L10n.t("Estimates of your income and wealth attract scams and quietly change the offers you see.")
        case .lead_generation: return L10n.t("One form fill can sell your phone number to dozens of buyers, which is the main reason spam calls and texts multiply.")
        case .real_estate: return L10n.t("Your address and what you owe are easy for investors, scammers and stalkers to use, but much of it is public record anyway.")
        case .consumer_reporting: return L10n.t("They can affect jobs, housing and loans, but credit and screening reports often stay on file by law, so opting out removes less.")
        case .recruiting: return L10n.t("Your résumé details can be scraped and used for fake job offers, but the harm is usually an annoyance or a scam attempt, not lasting damage.")
        case .political: return L10n.t("Mostly unwanted messages and solicitations. Voting records are public by law, so opting out limits only the commercial additions.")
        case .automotive: return L10n.t("Dealers and insurers learn about your car and when you may buy. Costly in rates at worst, rarely dangerous.")
        case .genealogy: return L10n.t("Few sites, and the exposure is mostly to relatives and addresses of living people. Low volume, so it is lower on the list.")
        case .b2b: return L10n.t("Mostly cold outreach to your work address. Annoying, and occasionally used to impersonate a boss, but it rarely reaches your home.")
        case .adtech: return L10n.t("Mostly tied to devices, not names, and there are over a hundred of them, so opting out of one removes little. Lowest value per site of the data-heavy types.")
        case .marketing_services: return L10n.t("They hold lists given to them by brands. Mostly junk mail, with a small breach risk.")
        case .other: return L10n.t("Does not fit a type, so read what they collect before deciding.")
        }
    }

    /// What a finished opt-out of this kind does for you, in plain words.
    var protects: String {
        switch self {
        case .people_search: return L10n.t("Strangers can no longer look you up on those sites to find your address, phone number and relatives.")
        case .arrests: return L10n.t("Old or dropped charges are harder for employers, landlords and neighbors to find on those sites.")
        case .consumer_reporting: return L10n.t("Less of your history is available to marketers, though credit and screening reports often stay on file by law.")
        case .marketing_data: return L10n.t("Fewer companies can sell lists with your name, address and habits, so there are fewer targeted scams and less junk mail and fewer calls.")
        case .b2b: return L10n.t("Your work email and phone are harder for salespeople and scammers to buy, so cold outreach to your work address drops.")
        case .adtech: return L10n.t("Fewer ad companies can trade your devices and browsing, so ads follow you around less.")
        case .healthcare: return L10n.t("Fewer companies can sell guesses about your health to marketers.")
        case .financial: return L10n.t("Fewer companies can sell estimates of your income and wealth, which means fewer scams aimed at you.")
        case .fraud_identity: return L10n.t("Some of your identity data is removed from their products, which shrinks what a breach or a wrong buyer could expose.")
        case .real_estate: return L10n.t("Your home and what you owe are harder for investors, scammers and stalkers to use.")
        case .genealogy: return L10n.t("Your record is hidden from family-tree searches, so strangers have a harder time finding living relatives.")
        case .lead_generation: return L10n.t("Your details are less likely to be resold as a lead, so there is less spam calling and texting.")
        case .political: return L10n.t("Less commercial data is added to the voter and donor lists used to target you.")
        case .recruiting: return L10n.t("Recruiters and scammers posting fake jobs can find you less easily through those sites.")
        case .automotive: return L10n.t("Dealers and insurers have less to go on about your car and when you might buy.")
        case .location_data: return L10n.t("Fewer companies can sell where your phone goes, which protects where you live, work and get care.")
        case .marketing_services: return L10n.t("Their campaigns stop mailing and emailing you.")
        case .other: return L10n.t("Those companies hold less of your data.")
        }
    }

    /// Every kind in the default order.
    static var ranked: [BrokerCategory] { allCases.sorted { $0.rank < $1.rank } }
}

/// A kind of data a broker's own pages say it handles. The ids match `tracks` in the `about:` block.
public extension BrokerCategory {
    /// What this kind of company does and how it uses and sells data, in plain words.
    var about: String {
        switch self {
        case .people_search: return L10n.t("Websites that gather public records, phone books and data bought from other brokers into a profile of you, then let anyone search by name, phone number or address. They earn from ads, subscriptions and paid reports.")
        case .arrests: return L10n.t("Sites that republish arrest, mugshot and court records from public sources. They earn from ads and, often, from charging people to take a record down. Because they copy records, the same record can sit on many of them.")
        case .consumer_reporting: return L10n.t("Companies that compile credit, rental, employment and background history into reports they sell to employers, landlords, lenders and insurers. Many are regulated by the Fair Credit Reporting Act.")
        case .marketing_data: return L10n.t("Companies that gather your name, address, shopping habits, income estimates and interests from many sources, then rent or sell lists of people like you to advertisers and mailers.")
        case .b2b: return L10n.t("Companies that sell business contact details (name, work email, phone, job title, employer) to sales and recruiting teams. They collect them from public profiles, company websites and other lists.")
        case .adtech: return L10n.t("Companies that run the behind-the-scenes auctions for online ads. They track your devices, browsing and apps with cookies and ad IDs, and trade that data with advertisers and publishers in milliseconds.")
        case .healthcare: return L10n.t("Companies that handle data about doctors, patients and health interests, sometimes built from pharmacy, insurance and web activity, and sell it to drug makers, health marketers and researchers.")
        case .financial: return L10n.t("Companies that gather credit, income and wealth information and sell it to lenders, marketers and investors.")
        case .fraud_identity: return L10n.t("Companies that match names, emails, phone numbers and addresses to check who someone is and to spot fraud. To do that they buy and keep large identity files, including past addresses and leaked passwords, and sell checks to banks, online shops and investigators.")
        case .real_estate: return L10n.t("Companies that combine property records, ownership and mortgage data and sell it to agents, investors and marketers.")
        case .genealogy: return L10n.t("Family-history sites that draw on public records, censuses and other databases to build family trees, sometimes including living people.")
        case .lead_generation: return L10n.t("Companies that collect your details through quote forms and surveys and sell them as leads to businesses such as insurers, lenders and home contractors.")
        case .political: return L10n.t("Companies that build voter files and donor lists from public voting records and purchased data, then sell targeting to campaigns and causes.")
        case .recruiting: return L10n.t("Companies that compile work history and contact details from public profiles and sell them to recruiters and employers.")
        case .automotive: return L10n.t("Companies that combine vehicle registrations, dealer records and driving data and sell them to dealers, insurers and marketers.")
        case .location_data: return L10n.t("Companies that buy location data from apps and devices and sell movement patterns to advertisers, retailers and sometimes governments.")
        case .marketing_services: return L10n.t("Agencies and mail houses that run campaigns for brands and handle large customer lists on their clients' behalf.")
        case .other: return L10n.t("Companies that hold personal data but do not fit the other types, such as software, media and research firms.")
        }
    }


    /// A realistic good outcome of this kind of company holding your data.
    var bestCase: String {
        switch self {
        case .people_search: return L10n.t("You look up an old friend, or check a contractor before letting them into your home.")
        case .arrests: return L10n.t("A neighbor or employer verifies a real, public record before a decision.")
        case .consumer_reporting: return L10n.t("A landlord quickly confirms you pay on time and approves your apartment.")
        case .marketing_data: return L10n.t("You get a coupon or offer for something you were about to buy anyway.")
        case .b2b: return L10n.t("A buyer finds the right person at your company and you get a useful deal or a job lead.")
        case .adtech: return L10n.t("Free apps and sites pay for themselves with ads that are somewhat relevant to you.")
        case .healthcare: return L10n.t("Researchers spot a drug side effect sooner from anonymous data, and you get a reminder for a screening you need.")
        case .financial: return L10n.t("A lender recognizes you as a good risk and offers a lower rate.")
        case .fraud_identity: return L10n.t("A bank spots that someone is using your name to open a credit card and blocks it before you ever find out.")
        case .real_estate: return L10n.t("A buyer's agent finds the owner of the house they want and you get a good offer.")
        case .genealogy: return L10n.t("You discover relatives you never knew and trace your family history.")
        case .lead_generation: return L10n.t("You ask for insurance quotes and get several useful offers fast.")
        case .political: return L10n.t("A campaign reaches you with information about issues you care about, or reminds you to vote.")
        case .recruiting: return L10n.t("A recruiter finds you for a real step up in a job without you searching.")
        case .automotive: return L10n.t("A dealer reminds you your lease is ending, or you are alerted to a safety recall.")
        case .location_data: return L10n.t("Disaster agencies see where people are moving to send help, or a traffic app reroutes you.")
        case .marketing_services: return L10n.t("A local shop you use sends a letter about a real sale.")
        case .other: return L10n.t("A service you chose works better, for example a contacts app that identifies callers.")
        }
    }

    /// A realistic bad outcome of this kind of company holding your data.
    var worstCase: String {
        switch self {
        case .people_search: return L10n.t("A stalker or abusive ex finds your new address within minutes of you moving, or a scammer uses your relatives' names to make a convincing call to your parents.")
        case .arrests: return L10n.t("A charge that was dropped years ago turns up when an employer or landlord searches your name, and you are asked to pay to have it removed.")
        case .consumer_reporting: return L10n.t("A mistaken record, such as someone else's debt or crime, appears in your report and costs you a job or a home before you find the error.")
        case .marketing_data: return L10n.t("A profile of your income, health interests and family is sold on to scammers, who use it to target you or your elderly relatives with convincing fake offers.")
        case .b2b: return L10n.t("Your work number and email are sold to hundreds of sales teams and scammers, and you spend your days deleting cold outreach or fending off someone impersonating your boss.")
        case .adtech: return L10n.t("Your browsing, including health or money worries, is traded and used to follow you with ads, or to build a profile that is later sold to people you would never choose.")
        case .healthcare: return L10n.t("A guess that you have a condition is sold to marketers and targets you with ads for it, and you cannot see or correct what they think you have.")
        case .financial: return L10n.t("Your estimated wealth makes you a target for scam calls and aggressive sales pitches, or a wrong estimate quietly gets you worse offers.")
        case .fraud_identity: return L10n.t("Their file leaks or is bought by a stalker or scammer, or a mistake in it flags you as a fraud risk and gets you declined for an account, with no easy way to see or fix why.")
        case .real_estate: return L10n.t("Investors and scammers know who owns which home, when it was bought and how much is owed, and pressure owners, especially older ones, into bad deals; a stalker gets your address.")
        case .genealogy: return L10n.t("A relative or stranger you have avoided finds you through a family tree, or your living relatives' details are exposed.")
        case .lead_generation: return L10n.t("One form fill sells your phone number to dozens of companies, and calls and texts follow for months, some from scammers.")
        case .political: return L10n.t("Your voting history and donations are used to target you with misleading messages, or your donor details are shared and you are flooded with solicitations.")
        case .recruiting: return L10n.t("Your résumé details are scraped and sold to scammers who post fake job offers to steal your identity or money.")
        case .automotive: return L10n.t("Your driving or vehicle history is sold to insurers who raise your rates, or dealers learn when you are likely to buy and pressure you.")
        case .location_data: return L10n.t("Your phone's movements show where you live, work, worship or get medical care, and are bought by anyone, including stalkers or authorities, to track you.")
        case .marketing_services: return L10n.t("A mail house is breached and the list it holds for many brands leaks, and you get junk mail you cannot trace back.")
        case .other: return L10n.t("Data you gave one company for one purpose is kept and sold elsewhere without you knowing.")
        }
    }

    /// What that means for the person, in plain words.
    var whatItMeans: String {
        switch self {
        case .people_search: return L10n.t("Anyone, including a stranger or an ex, can find where you live, your phone number and your relatives in seconds. Removing yourself here does the most for your safety.")
        case .arrests: return L10n.t("An old arrest or a dismissed case can follow you for years, and employers, landlords and neighbors can find it. These sites rarely tell you who else copied the record.")
        case .consumer_reporting: return L10n.t("What they hold can affect whether you get a job, an apartment or a loan. Opting out stops some marketing uses, but credit and screening reports often stay on file by law.")
        case .marketing_data: return L10n.t("This is why junk mail, calls and ads seem to know you. Opting out means less marketing aimed at you and fewer companies holding a profile of you.")
        case .b2b: return L10n.t("Your work email and phone number can be bought by salespeople you have never heard of. Opting out cuts cold calls and spam to your work address.")
        case .adtech: return L10n.t("Websites and apps pass your activity to them, so ads follow you across devices. They mostly know a device, not your name, but they can link the two.")
        case .healthcare: return L10n.t("Health-related guesses about you, such as conditions you search for or treat, can be sold for marketing. Opting out limits who can target you using your health.")
        case .financial: return L10n.t("Estimates of what you earn or are worth can change which offers you see, and they are sold without you asking.")
        case .fraud_identity: return L10n.t("The same file that helps a bank stop a thief is a prize for a thief, and it can be wrong. Opting out removes some data from their products, but some uses are exempt by law, so you may not be removed from everything.")
        case .real_estate: return L10n.t("Your address, what you paid and your mortgage are public in many places, and these companies package them so salespeople can find and contact owners.")
        case .genealogy: return L10n.t("They can reveal relatives and addresses of living people. Opting out hides your own record from searches.")
        case .lead_generation: return L10n.t("One quote request can sell your contact details to many companies, which is why calls and emails multiply after you fill in a form.")
        case .political: return L10n.t("Your party, voting history and donations, where public, are used to target you with political messages. Opting out limits what is added from commercial sources.")
        case .recruiting: return L10n.t("Your résumé details can be found and shared without you applying anywhere. Opting out stops recruiters finding you through them.")
        case .automotive: return L10n.t("Your car, your address and when you might buy again are shared with dealers and insurers. Opting out reduces targeted offers and some data used in insurance.")
        case .location_data: return L10n.t("Where you go, such as home, work or a clinic, can be inferred from your phone. This is among the most sensitive data, so opting out here matters.")
        case .marketing_services: return L10n.t("They hold mailing lists given to them and may add data from brokers. Opting out stops mail and email from their campaigns.")
        case .other: return L10n.t("What they hold varies, so read what they say they collect before deciding.")
        }
    }
}

public enum DataKind: String, CaseIterable, Sendable {
    case name, address, phone, email, age, relatives, employment, education, income, property, criminal, purchases, interests, online, location, health, social, credit

    public var title: String {
        switch self {
        case .name: return L10n.t("Names and aliases")
        case .address: return L10n.t("Home addresses")
        case .phone: return L10n.t("Phone numbers")
        case .email: return L10n.t("Email addresses")
        case .age: return L10n.t("Age or birthdate")
        case .relatives: return L10n.t("Relatives and household")
        case .employment: return L10n.t("Job and employer")
        case .education: return L10n.t("Education")
        case .income: return L10n.t("Income or wealth")
        case .property: return L10n.t("Property and vehicles")
        case .criminal: return L10n.t("Criminal and court records")
        case .purchases: return L10n.t("Shopping and purchases")
        case .interests: return L10n.t("Interests and demographics")
        case .online: return L10n.t("Devices and online activity")
        case .location: return L10n.t("Precise location")
        case .health: return L10n.t("Health information")
        case .social: return L10n.t("Social media profiles")
        case .credit: return L10n.t("Credit and financial accounts")
        }
    }
}

/// A kind of buyer or recipient a broker's privacy policy names. The ids match `sells_to` in the `about:` block.
public enum BuyerKind: String, CaseIterable, Sendable {
    case advertisers, brokers, employers, landlords, lenders, government, businesses, publishers, researchers, `public`

    public var title: String {
        switch self {
        case .advertisers: return L10n.t("Advertisers and marketers")
        case .brokers: return L10n.t("Other data brokers")
        case .employers: return L10n.t("Employers and recruiters")
        case .landlords: return L10n.t("Landlords")
        case .lenders: return L10n.t("Banks, lenders and insurers")
        case .government: return L10n.t("Government and law enforcement")
        case .businesses: return L10n.t("Business customers")
        case .publishers: return L10n.t("Publishers and ad platforms")
        case .researchers: return L10n.t("Researchers and nonprofits")
        case .public: return L10n.t("The general public")
        }
    }
}

public extension DirectoryEntry {
    var brokerCategory: BrokerCategory? { about.flatMap { BrokerCategory(rawValue: $0.category) } }
    var dataKinds: Set<DataKind> { Set((about?.tracks ?? []).compactMap(DataKind.init(rawValue:))) }
    var buyerKinds: Set<BuyerKind> { Set((about?.sellsTo ?? []).compactMap(BuyerKind.init(rawValue:))) }

    /// Whether the broker fits the chosen filters. A nil filter accepts everything; a broker we know nothing about fails any filter.
    func matches(category: BrokerCategory?, data: DataKind?, buyer: BuyerKind?) -> Bool {
        if let category, brokerCategory != category { return false }
        if let data, !dataKinds.contains(data) { return false }
        if let buyer, !buyerKinds.contains(buyer) { return false }
        return true
    }
}
