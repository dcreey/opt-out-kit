import json, os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import registries as R

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")


class Cleaning(unittest.TestCase):
    def test_messy_website_cells_become_real_domains(self):
        self.assertEqual(R.domains_in("acculeads.com; https://www.acculeads.com/privacy"), ["acculeads.com"])
        self.assertEqual(R.domains_in("com; exactmatch.io"), ["exactmatch.io"])
        self.assertEqual(R.domains_in("org; affordable-life-insurance-rates.org"), ["affordable-life-insurance-rates.org"])
        self.assertEqual(R.domains_in("http://a.example.com, b.example.org"), ["example.com", "example.org"])
        self.assertEqual(R.domains_in(""), [])
        self.assertEqual(R.domains_in("https"), [])

    def test_names_compare_without_company_suffixes_or_domain_endings(self):
        self.assertEqual(R.norm("FastPeopleSearch.com"), R.norm("FASTPEOPLESEARCH, LLC"))
        self.assertNotEqual(R.norm("Acme Data"), R.norm("Acme Marketing"))


class Parsing(unittest.TestCase):
    def test_california_csv(self):
        text = "﻿Data broker name:,DBA,Data broker primary website:,Email,Phone,Street,City,State,Zip,Country,Privacy site\n" \
               "Spokeo, Inc.,,www.spokeo.com,,,,,,,,https://www.spokeo.com/privacy\n"
        rows = R.parse_ca(text.replace("Spokeo, Inc.", '"Spokeo, Inc."'))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["primary"], "spokeo.com"); self.assertEqual(rows[0]["name"], "Spokeo, Inc.")

    def test_oregon_file_has_names_but_no_websites(self):
        line = "\t".join([" ", "DATA-00447", " ABOVE DATA INC   ", "Above Data   ", "30 Oak Knoll Dr", "San Anselmo", "CA", "CA", "94960"])
        rows = R.parse_or(line)
        self.assertEqual(rows[0]["name"], "Above Data Inc"); self.assertEqual(rows[0]["primary"], ""); self.assertEqual(rows[0]["reg_id"], "DATA-00447")

    def test_texas_rows(self):
        rows = [{"A": "Registration Number", "B": "Full Legal Name", "C": "Address", "D": "Email", "E": "Website", "F": "Consumer Rights Link"},
                {"A": "20260190", "B": "PHANTOM DATA LLC", "C": "x", "D": "y", "E": "phantomdata.com", "F": "https://phantomdata.com/privacy"}]
        out = R.parse_tx_rows([{"A": "Record Name:", "B": "x"}] + rows)
        self.assertEqual(out[0]["primary"], "phantomdata.com"); self.assertEqual(out[0]["reg_id"], "20260190")


class Merging(unittest.TestCase):
    def reg(self, code, brokers): return {"jurisdiction": code, "brokers": brokers}
    def rec(self, name, primary="", dba=""): return {"name": name, "dba": dba, "primary": primary, "sites": [primary] if primary else [], "privacy_url": "", "reg_id": ""}

    def test_a_broker_in_two_states_is_one_entry_and_a_name_only_record_joins_it(self):
        brokers, unresolved = R.merge({
            "CA": self.reg("CA", [self.rec("Acme Data LLC", "acme.com")]),
            "TX": self.reg("TX", [self.rec("ACME DATA, LLC", "acme.com")]),
            "OR": self.reg("OR", [self.rec("Acme Data Inc"), self.rec("Mystery Corp")]),
        })
        self.assertEqual(len(brokers), 1)
        self.assertEqual(brokers[0]["registered_in"], ["CA", "OR", "TX"])
        self.assertEqual([u["name"] for u in unresolved], ["Mystery Corp"])


class Shipped(unittest.TestCase):
    def test_the_joined_list_is_consistent_with_the_state_files(self):
        allb = json.load(open(os.path.join(ROOT, "registries", "all-brokers.json")))
        self.assertEqual(allb["count"], len(allb["brokers"]))
        states = {c for b in allb["brokers"] for c in b["registered_in"]}
        self.assertTrue({"CA", "TX", "OR"} <= states)
        ca = json.load(open(os.path.join(ROOT, "registries", "ca.json")))
        in_ca = {b["domain"] for b in allb["brokers"] if "CA" in b["registered_in"]}
        self.assertTrue(all(r["primary"] in in_ca for r in ca["brokers"] if r["primary"]))


if __name__ == "__main__":
    unittest.main()
