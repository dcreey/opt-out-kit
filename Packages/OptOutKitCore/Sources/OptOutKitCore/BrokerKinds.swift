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
