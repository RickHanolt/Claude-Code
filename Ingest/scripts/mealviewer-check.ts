/**
 * Parses a fixture taken verbatim from a live MealViewer response.
 *
 * The element names, the `i:nil` attribute spelling, the nesting of
 * FoodItemList/Data/FoodItem and the fact that category headers appear as
 * FoodItems all came from an actual fetch — not from documentation and not
 * from a guess. Two guesses about unseen response shapes have already cost
 * this project a day, so this feed got looked at before a line was written
 * against it.
 */
import { findBlock, parseMealViewer, summarize } from "../src/mealviewer";

// Trimmed for length: nutrition tables, allergens and the USDA statement are
// dropped. Everything structural is exactly as the feed returned it.
const FIXTURE = `<School xmlns:i="http://www.w3.org/2001/XMLSchema-instance" xmlns="http://schemas.datacontract.org/2004/07/MealViewerAPI.Models.Version4">
<MenuSchedules>
  <MenuSchedule>
    <DateInformation>
      <DateFull>2026-08-28T00:00:00</DateFull>
      <DateKey>20260828</DateKey>
      <WeekDayName>Friday</WeekDayName>
    </DateInformation>
    <MenuBlocks>
      <MenuBlock>
        <BlackedOut>false</BlackedOut>
        <BlockName>K-8 Express Lunch</BlockName>
        <CafeteriaLineList><Data><CafeteriaLine><FoodItemList><Data>
          <FoodItem>
            <Block_Name>K-8 Express Lunch</Block_Name>
            <Calories i:nil="true" />
            <Description></Description>
            <Item_Name>FEATURED ENTREES</Item_Name>
            <Item_Order_Id>1</Item_Order_Id>
            <Item_Type>ENTREES</Item_Type>
          </FoodItem>
          <FoodItem>
            <Block_Name>K-8 Express Lunch</Block_Name>
            <Calories>270</Calories>
            <Description>Juicy turkey hot dog served on whole wheat bun.</Description>
            <Item_Name>Uncured Hot Dog</Item_Name>
            <Item_Order_Id>2</Item_Order_Id>
            <Item_Type>ENTREES</Item_Type>
          </FoodItem>
          <FoodItem>
            <Block_Name>K-8 Express Lunch</Block_Name>
            <Calories>10</Calories>
            <Description>Sweet and tangy.</Description>
            <Item_Name>Ketchup</Item_Name>
            <Item_Order_Id>3</Item_Order_Id>
            <Item_Type>ENTREES</Item_Type>
          </FoodItem>
          <FoodItem>
            <Block_Name>K-8 Express Lunch</Block_Name>
            <Calories>92</Calories>
            <Item_Name>Seasoned Carrots (Local)</Item_Name>
            <Item_Order_Id>8</Item_Order_Id>
            <Item_Type>VEGETABLE</Item_Type>
          </FoodItem>
          <FoodItem>
            <Block_Name>K-8 Express Lunch</Block_Name>
            <Calories>110</Calories>
            <Item_Name>Chocolate Skim Milk (Local)</Item_Name>
            <Item_Order_Id>12</Item_Order_Id>
            <Item_Type>MILK</Item_Type>
          </FoodItem>
        </Data></FoodItemList></CafeteriaLine></Data></CafeteriaLineList>
      </MenuBlock>
      <MenuBlock>
        <BlackedOut>false</BlackedOut>
        <BlockName>Pre-K Breakfast</BlockName>
        <CafeteriaLineList><Data><CafeteriaLine><FoodItemList><Data>
          <FoodItem>
            <Calories>178</Calories>
            <Item_Name>Cinnamon French Toast</Item_Name>
            <Item_Type>ENTREES</Item_Type>
          </FoodItem>
        </Data></FoodItemList></CafeteriaLine></Data></CafeteriaLineList>
      </MenuBlock>
      <MenuBlock>
        <BlackedOut>false</BlackedOut>
        <BlockName>K-8 GNG Breakfast</BlockName>
        <CafeteriaLineList><Data><CafeteriaLine><FoodItemList><Data>
          <FoodItem>
            <Calories i:nil="true" />
            <Item_Name>FEATURED ENTREE</Item_Name>
            <Item_Type>ENTREES</Item_Type>
          </FoodItem>
          <FoodItem>
            <Calories>178</Calories>
            <Item_Name>Cinnamon French Toast</Item_Name>
            <Item_Type>ENTREES</Item_Type>
          </FoodItem>
        </Data></FoodItemList></CafeteriaLine></Data></CafeteriaLineList>
      </MenuBlock>
      <MenuBlock>
        <BlackedOut>false</BlackedOut>
        <BlockName>Pre-K Lunch</BlockName>
        <CafeteriaLineList><Data><CafeteriaLine><FoodItemList><Data>
          <FoodItem>
            <Calories>364</Calories>
            <Item_Name>Toasted Grilled Cheese</Item_Name>
            <Item_Type>ENTREES</Item_Type>
          </FoodItem>
        </Data></FoodItemList></CafeteriaLine></Data></CafeteriaLineList>
      </MenuBlock>
    </MenuBlocks>
  </MenuSchedule>
  <MenuSchedule>
    <DateInformation>
      <DateFull>2026-09-07T00:00:00</DateFull>
      <WeekDayName>Monday</WeekDayName>
    </DateInformation>
    <MenuBlocks>
      <MenuBlock>
        <BlackedOut>true</BlackedOut>
        <BlockName>K-8 Express Lunch</BlockName>
        <CafeteriaLineList><Data><CafeteriaLine><FoodItemList><Data />
        </FoodItemList></CafeteriaLine></Data></CafeteriaLineList>
      </MenuBlock>
    </MenuBlocks>
  </MenuSchedule>
</MenuSchedules>
</School>`;

let failures = 0;

function check(name: string, actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    console.error(`${name}: got ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`);
    failures += 1;
  }
}

const days = parseMealViewer(FIXTURE);

check("both days parse", days.length, 2);
check("date drops the zero time", days[0].date, "2026-08-28");
// Block order is taken from the live feed: Pre-K Breakfast is published
// BEFORE the K-8 one, so a lookup that ignored the grade band and took the
// first breakfast it found would quietly serve an eighth-grader the toddler
// menu — and would still pass a fixture that listed K-8 first.
check("all four blocks are found", days[0].blocks.length, 4);

// The whole reason this isn't string-matched on capitalisation.
check(
  "category headers are excluded",
  days[0].blocks[0].entrees,
  ["Uncured Hot Dog", "Ketchup"]
);

// Non-entrée courses are not the answer to "what's for lunch".
check(
  "vegetables and milk are not entrees",
  days[0].blocks[0].entrees.includes("Seasoned Carrots (Local)"),
  false
);

// Pre-K and K-8 are published side by side; picking the wrong one would hand
// an eighth-grader the toddler menu.
check(
  "the K-8 lunch block is selected, not Pre-K",
  findBlock(days[0], "K-8", "lunch")?.name,
  "K-8 Express Lunch"
);
check(
  "breakfast skips the Pre-K block listed before it",
  findBlock(days[0], "K-8", "breakfast")?.name,
  "K-8 GNG Breakfast"
);
check(
  "asking for Pre-K still gets Pre-K",
  findBlock(days[0], "Pre-K", "breakfast")?.name,
  "Pre-K Breakfast"
);

check("lunch summarizes to the entree", summarize(findBlock(days[0], "K-8", "lunch")), "Uncured Hot Dog · Ketchup");
check("breakfast summarizes", summarize(findBlock(days[0], "K-8", "breakfast")), "Cinnamon French Toast");

// A closure is the opposite of a menu, and is exactly what a parent needs.
check("a blacked-out day says so", summarize(findBlock(days[1], "K-8", "lunch")), "No meal served");

// No data must fall back to the kid's own default rather than print a
// placeholder that looks like information.
check("a missing block yields nothing", summarize(findBlock(days[0], "K-12", "lunch")), null);

if (failures > 0) {
  console.error(`${failures} mealviewer failure(s).`);
  process.exit(1);
}

console.log("MealViewer: all cases OK.");
