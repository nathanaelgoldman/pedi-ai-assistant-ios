//
//  ReportDataModels.swift
//  DrsMainApp
//
//  Created by yunastic on 11/3/25.
//
//
//  ReportDataModels.swift
//  DrsMainApp
//
//  Plain data structures for Well and Sick visit reports.
//  Rendering happens in ReportBuilder; DB fetching in ReportDataLoader.

// REPORT CONTRACT (Well visits)
// - Age gating lives in WellVisitReportRules + ReportDataLoader ONLY.
// - Age gating controls ONLY which fields appear INSIDE the current visit sections.
// - Growth charts, perinatal summary, and previous well visits are NEVER age-gated.
// - ReportBuilder is a dumb renderer: it prints whatever WellReportData gives it.
//- We don't make RTF (that is legacy from previous failed attempts)
//- we don't touch GrowthCharts
//- we work with PDF and Docx.
//- the contract is to filter the age appropriate current visit field to include in the report. Everything else is left unchanged.
//

import Foundation

// MARK: - Common

struct ReportMeta {
    let alias: String
    let mrn: String
    let name: String
    let dobISO: String
    let sex: String
    let visitDateISO: String
    let ageAtVisit: String
    let clinicianName: String
    let visitTypeReadable: String?   // well-only (e.g., "15-month visit")
    let createdAtISO: String?        // wired in a later step
    let updatedAtISO: String?        // wired in a later step
    let generatedAtISO: String       // now()
}

// MARK: - Well Visit

struct WellReportData {
    let meta: ReportMeta

    // Sections in the exact order we’ll render (some filled later)
    let perinatalSummary: String?
    let previousVisitFindings: [(title: String, date: String, findings: String?)]
    let currentVisitTitle: String
    let parentsConcerns: String?
    let feeding: [String: String]
    let supplementation: [String: String]
    let stool: [String: String]
    let sleep: [String: String]
    let developmental: [String: String]       // includes M-CHAT if present
    let milestonesAchieved: (achieved: Int, total: Int)
    let milestoneFlags: [String]
    let measurements: [String: String]        // today’s W/L/HC; weight-gain since discharge if available
    let physicalExamGroups: [(group: String, lines: [String])]
    let problemListing: String?
    let conclusions: String?
    let anticipatoryGuidance: String?
    let clinicianComments: String?
    let nextVisitDate: String?
    let growthCharts: [(title: String, imagePath: URL?)]
    let visibility: WellVisitReportRules.WellVisitVisibility?
}

// MARK: - Sick Visit

struct SickReportData {
    let meta: ReportMeta

    let mainComplaint: String?
    let hpi: String?
    let duration: String?
    let basics: [String: String]              // Feeding / Urination / Breathing / Pain / Context
    let pmh: String?
    let perinatalSummary: String?
    let vaccination: String?
    let vitalsSummary: [String]               // flagged items
    let physicalExamGroups: [(group: String, lines: [String])]
    let problemListing: String?
    let investigations: [String]
    let workingDiagnosis: String?
    let icd10: (code: String, label: String)?
    let planGuidance: String?
    let medications: [String]
    let clinicianComments: String?
    let nextVisitDate: String?
}
