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
        case .fraud_identity: return L10n.t("Companies that match names, emails, phone numbers and addresses to check who someone is and to spot fraud. They buy data from many sources and sell the checks to banks and online businesses.")
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
        case .fraud_identity: return L10n.t("They help stop scams but also keep detailed identity files on you. Opting out removes some of your data from their products, though some checks are required by law.")
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
