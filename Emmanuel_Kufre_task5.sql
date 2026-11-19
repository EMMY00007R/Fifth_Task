
   QUESTION 1
   Check whether email addresses in Person are correctly formatted.


SELECT
    personID,
    email,
    CASE
        WHEN email IS NULL THEN 'INVALID'
        WHEN email LIKE '% %' THEN 'INVALID'
        WHEN LEN(email) - LEN(REPLACE(email, '@', '')) <> 1 THEN 'INVALID'
        WHEN CHARINDEX('@', email) <= 1 THEN 'INVALID'
        WHEN CHARINDEX('.', email, CHARINDEX('@', email)) = 0 THEN 'INVALID'
        WHEN CHARINDEX('.', email, CHARINDEX('@', email)) = LEN(email) THEN 'INVALID'
        ELSE 'VALID'
    END AS EmailStatus
FROM Person;
GO


   QUESTION 2
   Summary of email service provider popularity.
  

SELECT
    LOWER(SUBSTRING(email, CHARINDEX('@', email) + 1, LEN(email))) AS EmailProvider,
    COUNT(*) AS NumberOfUsers,
    CAST(
        COUNT(*) * 100.0 /
        NULLIF(
            (SELECT COUNT(*) FROM Person WHERE email IS NOT NULL),
            0
        ) AS DECIMAL(5,2)
    ) AS Percentage
FROM Person
WHERE email IS NOT NULL
  AND CHARINDEX('@', email) > 0
GROUP BY LOWER(SUBSTRING(email, CHARINDEX('@', email) + 1, LEN(email)))
ORDER BY NumberOfUsers DESC;
GO


   QUESTION 3
   View: total call duration for each subscriber.
   Service IDs 1, 4 and 6 are treated as call services.
   

CREATE OR ALTER VIEW dbo.vw_TotalCallDuration
AS
SELECT
    s.subscriberID,
    s.phoneNumber,
    COALESCE(
        SUM(DATEDIFF(SECOND, p.connectionStart, p.connectionEnd)),
        0
    ) AS TotalCallDurationSeconds,
    CAST(
        COALESCE(
            SUM(DATEDIFF(SECOND, p.connectionStart, p.connectionEnd)),
            0
        ) / 60.0 AS DECIMAL(12,2)
    ) AS TotalCallDurationMinutes
FROM Subscriber s
LEFT JOIN P2PConnection p
    ON s.subscriberID = p.subscriberID
   AND p.serviceID IN (1, 4, 6)
GROUP BY
    s.subscriberID,
    s.phoneNumber;
GO

-- Test Q3:
-- SELECT * FROM dbo.vw_TotalCallDuration ORDER BY subscriberID;


   QUESTION 4
   View: longest call made by each person, including recipient.
  

CREATE OR ALTER VIEW dbo.vw_LongestCallPerPerson
AS
WITH RankedCalls AS
(
    SELECT
        pe.personID,
        pe.firstName,
        pe.lastName,
        s.subscriberID,
        s.phoneNumber AS CallerNumber,
        p.recipientNumber,
        p.connectionStart,
        p.connectionEnd,
        DATEDIFF(SECOND, p.connectionStart, p.connectionEnd) AS CallDurationSeconds,
        ROW_NUMBER() OVER
        (
            PARTITION BY pe.personID
            ORDER BY
                DATEDIFF(SECOND, p.connectionStart, p.connectionEnd) DESC,
                p.connectionStart
        ) AS rn
    FROM Person pe
    JOIN Subscriber s
        ON pe.personID = s.personID
    JOIN P2PConnection p
        ON s.subscriberID = p.subscriberID
    WHERE p.serviceID IN (1, 4, 6)
)
SELECT
    personID,
    firstName,
    lastName,
    subscriberID,
    CallerNumber,
    recipientNumber,
    connectionStart,
    connectionEnd,
    CallDurationSeconds,
    CAST(CallDurationSeconds / 60.0 AS DECIMAL(12,2)) AS CallDurationMinutes
FROM RankedCalls
WHERE rn = 1;
GO

-- Test Q4:
-- SELECT * FROM dbo.vw_LongestCallPerPerson;



   QUESTION 5
   View: subscriber with the highest transferred internet data
   for each mobile network operator.
   

CREATE OR ALTER VIEW dbo.vw_TopDataSubscriberPerOperator
AS
WITH DataUsage AS
(
    SELECT
        m.operatorID,
        m.operatorName,
        s.subscriberID,
        s.phoneNumber,
        SUM(ic.amountMB) AS TotalDataMB
    FROM MobileNetworkOperator m
    JOIN Plan p
        ON m.operatorID = p.operatorID
    JOIN Subscriber s
        ON p.planID = s.planID
    JOIN InternetConnection ic
        ON s.subscriberID = ic.subscriberID
    GROUP BY
        m.operatorID,
        m.operatorName,
        s.subscriberID,
        s.phoneNumber
),
RankedUsage AS
(
    SELECT
        *,
        ROW_NUMBER() OVER
        (
            PARTITION BY operatorID
            ORDER BY TotalDataMB DESC, subscriberID
        ) AS rn
    FROM DataUsage
)
SELECT
    operatorID,
    operatorName,
    subscriberID,
    phoneNumber,
    TotalDataMB
FROM RankedUsage
WHERE rn = 1;
GO

-- Test Q5:
-- SELECT * FROM dbo.vw_TopDataSubscriberPerOperator;



   QUESTION 6
   Scalar function: calculate the charge for a subscriber's
   local calls during a specified year and month.

   This uses serviceID = 1 and the applicable service price
   for the recipient's country zone.
   

CREATE OR ALTER FUNCTION dbo.fn_LocalCallCharges
(
    @SubscriberID INT,
    @Year INT,
    @Month INT
)
RETURNS DECIMAL(18,2)
AS
BEGIN
    DECLARE @TotalCharge DECIMAL(18,2);

    DECLARE @MonthStart DATE =
        DATEFROMPARTS(@Year, @Month, 1);

    DECLARE @NextMonth DATE =
        DATEADD(MONTH, 1, @MonthStart);

    SELECT
        @TotalCharge = COALESCE(
            SUM(
                (DATEDIFF(SECOND, pc.connectionStart, pc.connectionEnd) / 60.0)
                * sp.price
            ),
            0
        )
    FROM P2PConnection pc
    JOIN Country c
        ON c.countryCode = pc.recipientCountry
    JOIN Subscriber s
        ON s.subscriberID = pc.subscriberID
    JOIN Plan p
        ON p.planID = s.planID
    JOIN ServicePriceInZone sp
        ON sp.operatorID = p.operatorID
       AND sp.serviceID = 1
       AND sp.zoneID = c.zoneID
    WHERE pc.subscriberID = @SubscriberID
      AND pc.serviceID = 1
      AND pc.connectionStart >= @MonthStart
      AND pc.connectionStart < @NextMonth;

    RETURN COALESCE(@TotalCharge, 0);
END;
GO

-- Test Q6 (example):
-- SELECT dbo.fn_LocalCallCharges(3114, 2025, 6) AS LocalCallCharge;



   QUESTION 7
   Table-valued function: find subscriber pairs that communicated
   in both directions during a specified year and month.
   Calls and SMS are included (service IDs 1, 2, 4 and 5).
 

CREATE OR ALTER FUNCTION dbo.fn_BidirectionalCommunication
(
    @Year INT,
    @Month INT
)
RETURNS TABLE
AS
RETURN
(
    WITH MonthlyCommunication AS
    (
        SELECT DISTINCT
            a.subscriberID AS SubscriberA,
            b.subscriberID AS SubscriberB,
            a.phoneNumber AS PhoneNumberA,
            b.phoneNumber AS PhoneNumberB
        FROM Subscriber a
        JOIN P2PConnection pc
            ON pc.subscriberID = a.subscriberID
        JOIN Subscriber b
            ON b.phoneNumber = pc.recipientNumber
        WHERE pc.serviceID IN (1, 2, 4, 5)
          AND YEAR(pc.connectionStart) = @Year
          AND MONTH(pc.connectionStart) = @Month
          AND a.subscriberID <> b.subscriberID
    )
    SELECT DISTINCT
        x.SubscriberA,
        x.PhoneNumberA,
        x.SubscriberB,
        x.PhoneNumberB
    FROM MonthlyCommunication x
    WHERE EXISTS
    (
        SELECT 1
        FROM P2PConnection reverseCall
        JOIN Subscriber reverseSender
            ON reverseSender.subscriberID = reverseCall.subscriberID
        WHERE reverseSender.subscriberID = x.SubscriberB
          AND reverseCall.recipientNumber = x.PhoneNumberA
          AND reverseCall.serviceID IN (1, 2, 4, 5)
          AND YEAR(reverseCall.connectionStart) = @Year
          AND MONTH(reverseCall.connectionStart) = @Month
    )
      AND x.SubscriberA < x.SubscriberB
);
GO

-- Test Q7 (example):
-- SELECT * FROM dbo.fn_BidirectionalCommunication(2025, 6);


   QUESTION 8
   Stored procedure: renew a subscriber contract and carry forward
   active additional services, discounts and internet data plans.

   @ContractDurationMonths is required if contractEndDate is NULL.
   This is the corrected version tested with subscriber 3114.
   
CREATE OR ALTER PROCEDURE dbo.sp_RenewSubscriberContract
    @SubscriberID INT,
    @RenewalDate DATE = NULL,
    @ContractDurationMonths INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @OldStartDate DATE,
        @OldEndDate DATE,
        @NewStartDate DATE,
        @NewEndDate DATE,
        @ContractDurationDays INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT
            @OldStartDate = contractStartDate,
            @OldEndDate = contractEndDate
        FROM Subscriber WITH (UPDLOCK)
        WHERE subscriberID = @SubscriberID;

        IF @OldStartDate IS NULL
        BEGIN
            THROW 50001, 'Subscriber not found or contract start date is missing.', 1;
        END;

        -- Determine the previous contract duration
        IF @OldEndDate IS NOT NULL
        BEGIN
            SET @ContractDurationDays =
                DATEDIFF(DAY, @OldStartDate, @OldEndDate);
        END
        ELSE
        BEGIN
            IF @ContractDurationMonths IS NULL
               OR @ContractDurationMonths <= 0
            BEGIN
                THROW 50002,
                'Previous contract has no end date. Supply the contract duration in months.',
                1;
            END;
        END;

        -- Determine the renewal start date
        SET @NewStartDate = COALESCE(
            @RenewalDate,
            CASE
                WHEN @OldEndDate >= CAST(GETDATE() AS DATE)
                    THEN DATEADD(DAY, 1, @OldEndDate)
                ELSE CAST(GETDATE() AS DATE)
            END
        );

        -- Determine the new contract end date
        IF @OldEndDate IS NOT NULL
        BEGIN
            SET @NewEndDate = DATEADD(
                DAY,
                @ContractDurationDays,
                @NewStartDate
            );
        END
        ELSE
        BEGIN
            SET @NewEndDate = DATEADD(
                MONTH,
                @ContractDurationMonths,
                @NewStartDate
            );
        END;

        -- Update contract dates
        UPDATE Subscriber
        SET
            contractStartDate = @NewStartDate,
            contractEndDate = @NewEndDate
        WHERE subscriberID = @SubscriberID;

        -- Carry forward active additional services
        INSERT INTO OrderedAdditionalService
        (
            subscriberID,
            operatorAdditionalServiceID,
            orderDate,
            cancellationDate
        )
        SELECT
            subscriberID,
            operatorAdditionalServiceID,
            @NewStartDate,
            NULL
        FROM OrderedAdditionalService
        WHERE subscriberID = @SubscriberID
          AND orderDate <= COALESCE(@OldEndDate, @NewStartDate)
          AND (
              cancellationDate IS NULL
              OR cancellationDate >= @NewStartDate
          );

        -- Carry forward active discount packages
        INSERT INTO OrderedDiscount
        (
            subscriberID,
            packageID,
            orderDate,
            cancellationDate
        )
        SELECT
            subscriberID,
            packageID,
            @NewStartDate,
            NULL
        FROM OrderedDiscount
        WHERE subscriberID = @SubscriberID
          AND orderDate <= COALESCE(@OldEndDate, @NewStartDate)
          AND (
              cancellationDate IS NULL
              OR cancellationDate >= @NewStartDate
          );

        -- Carry forward active internet plans
        INSERT INTO OrderedInternetDataPlan
        (
            internetDataPlanID,
            subscriberID,
            orderDate,
            cancellationDate
        )
        SELECT
            internetDataPlanID,
            subscriberID,
            @NewStartDate,
            NULL
        FROM OrderedInternetDataPlan
        WHERE subscriberID = @SubscriberID
          AND orderDate <= COALESCE(@OldEndDate, @NewStartDate)
          AND (
              cancellationDate IS NULL
              OR cancellationDate >= @NewStartDate
          );

        COMMIT TRANSACTION;

        SELECT
            @SubscriberID AS SubscriberID,
            @NewStartDate AS NewContractStartDate,
            @NewEndDate AS NewContractEndDate,
            'Contract renewed successfully' AS Result;

    END TRY
    BEGIN CATCH

        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        THROW;

    END CATCH;
END;
GO

-- Q8 TEST - EXEC dbo.sp_RenewSubscriberContract
    @SubscriberID = 3114,
    @ContractDurationMonths = 24;

   EXEC dbo.sp_RenewSubscriberContract
    @SubscriberID = 3114; 



   QUESTION 9
   Multi-statement table-valued function: monthly bill breakdown.

   Returns a row for each category and a TOTAL row.
   The function below is the version that was created and tested
   successfully in the conversation.
  

CREATE OR ALTER FUNCTION dbo.fn_MonthlySubscriberBill
(
    @SubscriberID INT,
    @BillYear INT,
    @BillMonth INT
)
RETURNS @Bill TABLE
(
    ChargeCategory VARCHAR(50),
    Description VARCHAR(150),
    Amount DECIMAL(18,2)
)
AS
BEGIN
    DECLARE @MonthStart DATE =
        DATEFROMPARTS(@BillYear, @BillMonth, 1);

    DECLARE @MonthEnd DATE =
        EOMONTH(@MonthStart);

    DECLARE @DaysInMonth INT =
        DAY(@MonthEnd);

    DECLARE @PlanID INT;
    DECLARE @OperatorID INT;
    DECLARE @PlanPrice DECIMAL(18,4);
    DECLARE @PersonID INT;
    DECLARE @InternetPlanID INT;

    SELECT
        @PlanID = p.planID,
        @OperatorID = p.operatorID,
        @PlanPrice = p.price,
        @PersonID = s.personID,
        @InternetPlanID = p.internetDataPlanID
    FROM Subscriber s
    JOIN Plan p
        ON p.planID = s.planID
    WHERE s.subscriberID = @SubscriberID;

    IF @PlanID IS NULL
        RETURN;

    -- 1. Monthly plan charge.
    INSERT INTO @Bill
    VALUES ('Plan', 'Monthly subscription plan', @PlanPrice);

    -- 2. Calls, SMS, MMS and video calls.
    ;WITH UsageData AS
    (
        SELECT
            pc.serviceID,
            COUNT(*) AS TotalUnits,
            SUM(
                DATEDIFF(
                    SECOND,
                    pc.connectionStart,
                    pc.connectionEnd
                )
            ) AS TotalSeconds
        FROM P2PConnection pc
        WHERE pc.subscriberID = @SubscriberID
          AND pc.connectionStart >= @MonthStart
          AND pc.connectionStart < DATEADD(DAY, 1, @MonthEnd)
        GROUP BY pc.serviceID
    ),
    Allowances AS
    (
        SELECT
            pb.serviceID,
            SUM(
                COALESCE(dp.quantity, 0) *
                CASE
                    WHEN od.subscriberID IS NULL THEN 0
                    ELSE
                    (
                        DATEDIFF(
                            DAY,
                            CASE
                                WHEN od.orderDate < @MonthStart
                                THEN @MonthStart
                                ELSE od.orderDate
                            END,
                            DATEADD(
                                DAY,
                                1,
                                CASE
                                    WHEN od.cancellationDate IS NULL
                                      OR od.cancellationDate > @MonthEnd
                                    THEN @MonthEnd
                                    ELSE od.cancellationDate
                                END
                            )
                        ) * 1.0 / @DaysInMonth
                    )
                END
            ) AS FreeUnits
        FROM OrderedDiscount od
        JOIN DiscountPackage dp
            ON dp.packageID = od.packageID
        JOIN PlanBundle pb
            ON pb.bundleID = dp.bundleID
        WHERE od.subscriberID = @SubscriberID
          AND od.orderDate <= @MonthEnd
          AND (
                od.cancellationDate IS NULL
                OR od.cancellationDate >= @MonthStart
              )
          AND pb.planID = @PlanID
        GROUP BY pb.serviceID
    )
    INSERT INTO @Bill
    SELECT
        CASE u.serviceID
            WHEN 1 THEN 'Calls'
            WHEN 2 THEN 'SMS'
            WHEN 3 THEN 'Other services'
            WHEN 4 THEN 'Calls'
            WHEN 5 THEN 'SMS'
            WHEN 6 THEN 'Other services'
        END,
        CASE u.serviceID
            WHEN 1 THEN 'Local calls'
            WHEN 2 THEN 'Local SMS'
            WHEN 3 THEN 'MMS'
            WHEN 4 THEN 'International calls'
            WHEN 5 THEN 'International SMS'
            WHEN 6 THEN 'Video calls'
        END,
        CAST(
            CASE
                WHEN u.serviceID = 4 THEN
                (
                    SELECT COALESCE(
                        SUM(
                            DATEDIFF(
                                SECOND,
                                pc.connectionStart,
                                pc.connectionEnd
                            ) / 60.0 * sp.price
                        ),
                        0
                    )
                    FROM P2PConnection pc
                    JOIN Country c
                        ON c.countryCode = pc.recipientCountry
                    JOIN ServicePriceInZone sp
                        ON sp.operatorID = @OperatorID
                       AND sp.serviceID = 4
                       AND sp.zoneID = c.zoneID
                    WHERE pc.subscriberID = @SubscriberID
                      AND pc.serviceID = 4
                      AND pc.connectionStart >= @MonthStart
                      AND pc.connectionStart < DATEADD(DAY, 1, @MonthEnd)
                )
                ELSE
                    CASE
                        WHEN pb.price = 0 THEN 0
                        ELSE
                            CASE
                                WHEN u.serviceID IN (1, 4, 6)
                                THEN
                                    CASE
                                        WHEN u.TotalSeconds / 60.0
                                             - COALESCE(a.FreeUnits, 0) > 0
                                        THEN
                                            (
                                                u.TotalSeconds / 60.0
                                                - COALESCE(a.FreeUnits, 0)
                                            ) * pb.price
                                        ELSE 0
                                    END
                                ELSE
                                    CASE
                                        WHEN u.TotalUnits
                                             - COALESCE(a.FreeUnits, 0) > 0
                                        THEN
                                            (
                                                u.TotalUnits
                                                - COALESCE(a.FreeUnits, 0)
                                            ) * pb.price
                                        ELSE 0
                                    END
                            END
                    END
            END AS DECIMAL(18,2)
        )
    FROM UsageData u
    LEFT JOIN PlanBundle pb
        ON pb.planID = @PlanID
       AND pb.serviceID = u.serviceID
    LEFT JOIN Allowances a
        ON a.serviceID = u.serviceID;

    -- 3. Internet usage using the internet plan linked to Plan.
    DECLARE @DataUsed DECIMAL(18,4) = 0;
    DECLARE @DataAllowance DECIMAL(18,4) = 0;
    DECLARE @DataPrice DECIMAL(18,4) = 0;
    DECLARE @ExtraPrice DECIMAL(18,4) = 0;
    DECLARE @InternetCharge DECIMAL(18,4) = 0;

    SELECT
        @DataUsed = COALESCE(SUM(amountMB), 0)
    FROM InternetConnection
    WHERE subscriberID = @SubscriberID
      AND connectionStart >= @MonthStart
      AND connectionStart < DATEADD(DAY, 1, @MonthEnd);

    SELECT TOP 1
        @DataAllowance = dataAllowanceMB,
        @DataPrice = price,
        @ExtraPrice = COALESCE(additionalPrice, 0)
    FROM InternetDataPlan
    WHERE internetDataPlanID = @InternetPlanID;

    SET @InternetCharge =
        @DataPrice +
        CASE
            WHEN @DataUsed > @DataAllowance
            THEN (@DataUsed - @DataAllowance) * @ExtraPrice
            ELSE 0
        END;

    INSERT INTO @Bill
    VALUES
    (
        'Internet',
        'Internet usage',
        CAST(@InternetCharge AS DECIMAL(18,2))
    );

    -- 4. Ordered additional services, prorated by active days.
    INSERT INTO @Bill
    SELECT
        'Additional services',
        a.additionalServiceName,
        CAST(
            oa.price *
            (
                DATEDIFF(
                    DAY,
                    CASE
                        WHEN o.orderDate < @MonthStart
                        THEN @MonthStart
                        ELSE o.orderDate
                    END,
                    DATEADD(
                        DAY,
                        1,
                        CASE
                            WHEN o.cancellationDate IS NULL
                              OR o.cancellationDate > @MonthEnd
                            THEN @MonthEnd
                            ELSE o.cancellationDate
                        END
                    )
                ) * 1.0 / @DaysInMonth
            )
            AS DECIMAL(18,2)
        )
    FROM OrderedAdditionalService o
    JOIN OperatorAdditionalService oa
        ON oa.operatorAdditionalServiceID =
           o.operatorAdditionalServiceID
    JOIN AdditionalService a
        ON a.additionalServiceID = oa.additionalServiceID
    WHERE o.subscriberID = @SubscriberID
      AND o.orderDate <= @MonthEnd
      AND (
            o.cancellationDate IS NULL
            OR o.cancellationDate >= @MonthStart
          );

    -- 5. Final total.
    INSERT INTO @Bill
    SELECT
        'TOTAL',
        'Total amount payable',
        CAST(COALESCE(SUM(Amount), 0) AS DECIMAL(18,2))
    FROM @Bill;

    RETURN;
END;
GO

-- Test Q9 for subscriber 3114, November 2026:
-- SELECT *
-- FROM dbo.fn_MonthlySubscriberBill(3114, 2026, 11);

-- Test Q9 for subscriber 3114, July 2026:
-- SELECT *
-- FROM dbo.fn_MonthlySubscriberBill(3114, 2026, 7);


