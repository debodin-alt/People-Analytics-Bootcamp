-- Document a known, deliberate variance from the PRD's printed figure.
--
-- PRD §5 defines voluntary attrition as:
--     voluntary terms TTM ÷ average active headcount,
--     average = (start + end) ÷ 2
-- but prints the value as 8.9%.
--
-- Against this dataset, with the corrected workforce boundary:
--     terms = 73          (matches the PRD's stated count exactly)
--     start = 794, end = 820, average = 807  ->  73/807 = 9.0%
--     ending headcount only              820  ->  73/820 = 8.9%
--
-- The printed 8.9% is therefore computed against ENDING headcount, which
-- contradicts the PRD's own written definition. This implementation
-- follows the written definition (9.0%).
--
-- That is the correct methodology, not merely a defensible one: dividing
-- by ending headcount understates attrition whenever the workforce grew
-- during the period, because the leavers were drawn from a population
-- smaller than the denominator. Meridian grew 794 -> 820 over this
-- window, so ending headcount flatters the rate. Average headcount is
-- the standard actuarial treatment for exactly this reason.
--
-- Surface this variance on the Methodology page rather than leaving a
-- reader to discover that the platform and the source PRD disagree.

comment on function metrics.voluntary_attrition_rate_ttm(text[], text[], text[], text[]) is
  'Voluntary terms in the trailing 12 months from workforce_boundary(), divided by average active headcount ((start+end)/2) per PRD §5. Returns 9.0% on the reference dataset; the PRD prints 8.9% because that figure divides by ending headcount, contradicting its own definition. Suppressed below minimum cell size.';
